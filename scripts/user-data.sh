#!/bin/bash
set -exo pipefail
exec > /var/log/user-data.log 2>&1

# --- Install dependencies ---
yum install -y git java-21-amazon-corretto-devel protobuf-compiler protobuf-devel rust cargo cmake cronie
yum groupinstall -y 'Development Tools'
export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto
echo 'export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto' >> /etc/profile.d/java.sh
sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' >> /etc/sysctl.conf

# --- Step 1: Clone and build OpenSearch ---
su -l ec2-user -c 'git clone --branch {{BRANCH}} {{OPENSEARCH_REPO}} /home/ec2-user/opensearch-src'
su -l ec2-user -c 'cd /home/ec2-user/opensearch-src && ./gradlew publishToMavenLocal'

# --- Step 2: Clone and build SQL plugin (skipped) ---
# su -l ec2-user -c 'git clone --branch {{SQL_PLUGIN_BRANCH}} {{SQL_PLUGIN_REPO}} /home/ec2-user/sql-plugin'
# su -l ec2-user -c 'cd /home/ec2-user/sql-plugin && ./gradlew publishToMavenLocal'

# --- Step 3: Build local distribution ---
su -l ec2-user -c 'cd /home/ec2-user/opensearch-src && ./gradlew localDistro'

# --- Step 4: Extract the local distribution ---
su -l ec2-user -c 'mkdir -p /home/ec2-user/opensearch && cp -r /home/ec2-user/opensearch-src/build/distribution/local/opensearch-*/* /home/ec2-user/opensearch/'

# --- Step 5: Install plugins (skipped) ---
# su -l ec2-user -c '/home/ec2-user/opensearch/bin/opensearch-plugin install --batch org.opensearch.plugin:opensearch-job-scheduler:3.3.0.0'
# su -l ec2-user -c '/home/ec2-user/opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/sql-plugin/plugin/build/distributions/opensearch-sql-plugin-*.zip'
# su -l ec2-user -c '/home/ec2-user/opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/opensearch-src/plugins/engine-datafusion/build/distributions/engine-datafusion-*.zip'

# --- Step 6: Install async-profiler ---
su -l ec2-user -c 'mkdir -p /home/ec2-user/async-profiler'
su -l ec2-user -c 'curl -L -o /home/ec2-user/async-profiler/async-profiler.tar.gz https://github.com/async-profiler/async-profiler/releases/download/v3.0/async-profiler-3.0-linux-arm64.tar.gz'
su -l ec2-user -c 'tar xzf /home/ec2-user/async-profiler/async-profiler.tar.gz -C /home/ec2-user/async-profiler --strip-components=1'

# --- Profiling script (profiles CPU for 60s, saves flamegraph HTML, uploads to S3) ---
cat > /home/ec2-user/profile-opensearch.sh << 'SCRIPT'
#!/bin/bash
set -eo pipefail
PROFILER=/home/ec2-user/async-profiler/bin/asprof
OUTPUT_DIR=/home/ec2-user/profiles
S3_BUCKET={{S3_PROFILE_BUCKET}}
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname)
PID=$(pgrep -f opensearch-src || pgrep -f 'org.opensearch.bootstrap.OpenSearch' || true)
if [ -z "$PID" ]; then
  echo "OpenSearch not running, skipping profile"
  exit 0
fi
FILENAME="cpu_${HOSTNAME}_${TIMESTAMP}.html"
$PROFILER -d 60 -f "$OUTPUT_DIR/$FILENAME" "$PID"
aws s3 cp "$OUTPUT_DIR/$FILENAME" "s3://$S3_BUCKET/$HOSTNAME/$FILENAME"
SCRIPT
chmod +x /home/ec2-user/profile-opensearch.sh
chown ec2-user:ec2-user /home/ec2-user/profile-opensearch.sh

# --- Cron: run CPU profile every 5 minutes ---
systemctl enable crond
systemctl start crond
echo '*/5 * * * * /home/ec2-user/profile-opensearch.sh >> /home/ec2-user/profile-cron.log 2>&1' | crontab -u ec2-user -

# --- Logrotate for OpenSearch and profiler logs ---
cat > /etc/logrotate.d/opensearch-profiler << 'LOGROTATE'
/home/ec2-user/opensearch-run.log
/home/ec2-user/profile-cron.log {
    size 100M
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0644 ec2-user ec2-user
}
LOGROTATE

# --- Step 7: Configure OpenSearch for external access ---
cat > /home/ec2-user/opensearch/config/opensearch.yml << 'EOF'
node.name: node-1
cluster.name: my-application
network.host: 0.0.0.0
cluster.initial_cluster_manager_nodes: ["node-1"]
EOF
chown ec2-user:ec2-user /home/ec2-user/opensearch/config/opensearch.yml

# --- Step 7b: Configure JVM heap ---
sed -i 's/^-Xms.*/-Xms{{JVM_HEAP}}/' /home/ec2-user/opensearch/config/jvm.options
sed -i 's/^-Xmx.*/-Xmx{{JVM_HEAP}}/' /home/ec2-user/opensearch/config/jvm.options

# --- Step 8: Start OpenSearch ---
su -l ec2-user -c 'nohup /home/ec2-user/opensearch/bin/opensearch > /home/ec2-user/opensearch-run.log 2>&1 &'
