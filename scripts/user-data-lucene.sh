#!/bin/bash
set -exo pipefail
exec > /var/log/user-data.log 2>&1

# =============================================================================
# user-data-lucene.sh — Builds vanilla Lucene OpenSearch from source
# =============================================================================

# --- Step 1: Install dependencies ---
yum install -y git java-21-amazon-corretto-devel protobuf-compiler protobuf-devel rust cargo cmake cronie
yum groupinstall -y 'Development Tools'
export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto
echo 'export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto' >> /etc/profile.d/java.sh
sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' >> /etc/sysctl.conf

# --- Step 2: Clone and build OpenSearch ---
su -l ec2-user -c 'git clone --branch {{LUCENE_BRANCH}} {{LUCENE_REPO}} /home/ec2-user/lucene-opensearch-src'
su -l ec2-user -c 'cd /home/ec2-user/lucene-opensearch-src && ./gradlew publishToMavenLocal -x missingJavadoc'

# --- Step 3: Clone and build SQL plugin ---
su -l ec2-user -c 'git clone --branch {{LUCENE_SQL_BRANCH}} {{LUCENE_SQL_REPO}} /home/ec2-user/lucene-sql-plugin'
su -l ec2-user -c 'cd /home/ec2-user/lucene-sql-plugin && ./gradlew publishToMavenLocal'

# --- Step 4: Build local distribution ---
su -l ec2-user -c 'cd /home/ec2-user/lucene-opensearch-src && ./gradlew localDistro -x missingJavadoc'

# --- Step 5: Extract the local distribution ---
su -l ec2-user -c 'mkdir -p /home/ec2-user/lucene-opensearch && cp -r /home/ec2-user/lucene-opensearch-src/build/distribution/local/opensearch-*/* /home/ec2-user/lucene-opensearch/'

# --- Step 6: Build and install plugins ---
su -l ec2-user -c 'git clone --branch {{LUCENE_BRANCH}} https://github.com/opensearch-project/job-scheduler.git /home/ec2-user/lucene-job-scheduler'
su -l ec2-user -c 'cd /home/ec2-user/lucene-job-scheduler && ./gradlew assemble'
su -l ec2-user -c 'JOB_ZIP=$(ls /home/ec2-user/lucene-job-scheduler/build/distributions/opensearch-job-scheduler-*-SNAPSHOT.zip | head -1) && /home/ec2-user/lucene-opensearch/bin/opensearch-plugin install --batch "file://$JOB_ZIP"'
su -l ec2-user -c 'SQL_ZIP=$(ls /home/ec2-user/lucene-sql-plugin/plugin/build/distributions/opensearch-sql-*-SNAPSHOT.zip | head -1) && /home/ec2-user/lucene-opensearch/bin/opensearch-plugin install --batch "file://$SQL_ZIP"'

# --- Step 7: Configure OpenSearch ---
cat > /home/ec2-user/lucene-opensearch/config/opensearch.yml << 'EOF'
node.name: node-1
cluster.name: lucene-cluster
network.host: 0.0.0.0
cluster.initial_cluster_manager_nodes: ["node-1"]
EOF
chown ec2-user:ec2-user /home/ec2-user/lucene-opensearch/config/opensearch.yml

# --- Step 8: Configure JVM heap ---
sed -i 's/^-Xms.*/-Xms{{JVM_HEAP}}/' /home/ec2-user/lucene-opensearch/config/jvm.options
sed -i 's/^-Xmx.*/-Xmx{{JVM_HEAP}}/' /home/ec2-user/lucene-opensearch/config/jvm.options

# --- Step 9: Write env file and clone automation scripts ---
cat > /home/ec2-user/.opensearch-env << 'ENVEOF'
ENGINE=lucene
S3_BUCKET={{S3_PROFILE_BUCKET}}
ENVEOF
chown ec2-user:ec2-user /home/ec2-user/.opensearch-env

su -l ec2-user -c 'git clone https://github.com/HarishNarasimhanK/opensearch-test-automation.git /home/ec2-user/opensearch-test-automation'

# --- Step 10: Install async-profiler ---
su -l ec2-user -c 'mkdir -p /home/ec2-user/async-profiler'
su -l ec2-user -c 'curl -L -o /home/ec2-user/async-profiler/async-profiler.tar.gz https://github.com/async-profiler/async-profiler/releases/download/v3.0/async-profiler-3.0-linux-arm64.tar.gz'
su -l ec2-user -c 'tar xzf /home/ec2-user/async-profiler/async-profiler.tar.gz -C /home/ec2-user/async-profiler --strip-components=1'

# --- Step 11: Setup cron and logrotate ---
systemctl enable crond
systemctl start crond
echo '*/5 * * * * /home/ec2-user/opensearch-test-automation/profiler/profile-opensearch.sh >> /home/ec2-user/profile-cron.log 2>&1' | crontab -u ec2-user -

cat > /etc/logrotate.d/opensearch-profiler << 'LOGROTATE'
/home/ec2-user/lucene-opensearch-run.log
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

# --- Step 12: Start OpenSearch ---
su -l ec2-user -c 'nohup /home/ec2-user/lucene-opensearch/bin/opensearch > /home/ec2-user/lucene-opensearch-run.log 2>&1 &'
