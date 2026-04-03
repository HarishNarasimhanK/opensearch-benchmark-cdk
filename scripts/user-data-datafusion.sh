#!/bin/bash
set -exo pipefail
exec > /var/log/user-data.log 2>&1

# =============================================================================
# user-data-datafusion.sh — Builds OpenSearch with DataFusion engine from source
# =============================================================================

# --- Step 1: Install dependencies ---
yum install -y git java-21-amazon-corretto-devel protobuf-compiler protobuf-devel rust cargo cmake cronie amazon-cloudwatch-agent
yum groupinstall -y 'Development Tools'
export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto
echo 'export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto' >> /etc/profile.d/java.sh
sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' >> /etc/sysctl.conf

# --- Step 2: Start CloudWatch agent early (streams user-data.log from the start) ---
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
  "metrics": {
    "namespace": "OpenSearch/DataFusion",
    "metrics_collected": {
      "cpu": { "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"], "metrics_collection_interval": 10 },
      "mem": { "measurement": ["mem_used_percent", "mem_available_percent"], "metrics_collection_interval": 10 },
      "disk": { "measurement": ["disk_used_percent"], "resources": ["/"], "metrics_collection_interval": 60 },
      "diskio": { "measurement": ["reads", "writes", "read_bytes", "write_bytes"], "metrics_collection_interval": 10 },
      "net": { "measurement": ["bytes_sent", "bytes_recv"], "metrics_collection_interval": 10 }
    },
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/user-data.log", "log_group_name": "/opensearch/datafusion/user-data", "log_stream_name": "{instance_id}" },
          { "file_path": "/home/ec2-user/datafusion-opensearch-run.log", "log_group_name": "/opensearch/datafusion/runtime", "log_stream_name": "{instance_id}" }
        ]
      }
    }
  }
}
CWCONFIG
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

# --- Step 3: Clone and build OpenSearch ---
su -l ec2-user -c 'git clone --branch {{BRANCH}} {{OPENSEARCH_REPO}} /home/ec2-user/datafusion-opensearch-src'
su -l ec2-user -c 'cd /home/ec2-user/datafusion-opensearch-src && ./gradlew publishToMavenLocal -x missingJavadoc'

# --- Step 3: Clone and build SQL plugin ---
su -l ec2-user -c 'git clone --branch {{SQL_PLUGIN_BRANCH}} {{SQL_PLUGIN_REPO}} /home/ec2-user/datafusion-sql-plugin'
su -l ec2-user -c 'cd /home/ec2-user/datafusion-sql-plugin && ./gradlew publishToMavenLocal'

# --- Step 4: Build local distribution ---
su -l ec2-user -c 'cd /home/ec2-user/datafusion-opensearch-src && ./gradlew localDistro -x missingJavadoc'

# --- Step 5: Extract the local distribution ---
su -l ec2-user -c 'mkdir -p /home/ec2-user/datafusion-opensearch && cp -r /home/ec2-user/datafusion-opensearch-src/build/distribution/local/opensearch-*/* /home/ec2-user/datafusion-opensearch/'

# --- Step 6: Build and install plugins ---
su -l ec2-user -c 'cd /home/ec2-user/datafusion-opensearch-src && ./gradlew :plugins:engine-datafusion:bundlePlugin :sandbox:plugins:analytics-engine:bundlePlugin -x missingJavadoc'
su -l ec2-user -c '/home/ec2-user/datafusion-opensearch/bin/opensearch-plugin install --batch org.opensearch.plugin:opensearch-job-scheduler:3.3.0.0'
su -l ec2-user -c '/home/ec2-user/datafusion-opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/datafusion-sql-plugin/plugin/build/distributions/opensearch-sql-3.3.0.0-SNAPSHOT.zip'
su -l ec2-user -c '/home/ec2-user/datafusion-opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/datafusion-opensearch-src/sandbox/plugins/analytics-engine/build/distributions/analytics-engine-3.3.0-SNAPSHOT.zip'
# Remove duplicate jars from already-installed plugins to avoid jar hell
su -l ec2-user -c '
PLUGIN_DIR=/home/ec2-user/datafusion-opensearch/plugins
NEW_ZIP=/home/ec2-user/datafusion-opensearch-src/plugins/engine-datafusion/build/distributions/engine-datafusion-3.3.0-SNAPSHOT.zip
NEW_JARS=$(unzip -l "$NEW_ZIP" | grep "\.jar$" | awk "{print \$NF}" | xargs -I{} basename {})
for jar in $NEW_JARS; do
  found=$(find "$PLUGIN_DIR" -name "$jar" 2>/dev/null)
  if [ -n "$found" ]; then
    echo "Removing duplicate jar to avoid jar hell: $found"
    rm -f $found
  fi
done
'
su -l ec2-user -c '/home/ec2-user/datafusion-opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/datafusion-opensearch-src/plugins/engine-datafusion/build/distributions/engine-datafusion-3.3.0-SNAPSHOT.zip'

# --- Step 7: Configure OpenSearch ---
cat > /home/ec2-user/datafusion-opensearch/config/opensearch.yml << 'EOF'
node.name: node-1
cluster.name: datafusion-cluster
network.host: 0.0.0.0
cluster.initial_cluster_manager_nodes: ["node-1"]
EOF
chown ec2-user:ec2-user /home/ec2-user/datafusion-opensearch/config/opensearch.yml

# --- Step 8: Configure JVM heap ---
sed -i 's/^-Xms.*/-Xms{{JVM_HEAP}}/' /home/ec2-user/datafusion-opensearch/config/jvm.options
sed -i 's/^-Xmx.*/-Xmx{{JVM_HEAP}}/' /home/ec2-user/datafusion-opensearch/config/jvm.options

# --- Step 9: Write env file and clone automation scripts ---
cat > /home/ec2-user/.opensearch-env << 'ENVEOF'
ENGINE=datafusion
S3_BUCKET={{S3_PROFILE_BUCKET}}
ENVEOF
chown ec2-user:ec2-user /home/ec2-user/.opensearch-env

su -l ec2-user -c 'aws s3 cp {{SCRIPTS_S3_PATH}} /tmp/automation-scripts.zip && mkdir -p /home/ec2-user/opensearch-test-automation && cd /home/ec2-user/opensearch-test-automation && unzip -o /tmp/automation-scripts.zip && chmod +x /home/ec2-user/opensearch-test-automation/**/*.sh && rm /tmp/automation-scripts.zip'

# --- Step 10: Install async-profiler ---
su -l ec2-user -c 'mkdir -p /home/ec2-user/async-profiler'
su -l ec2-user -c 'curl -L -o /home/ec2-user/async-profiler/async-profiler.tar.gz https://github.com/async-profiler/async-profiler/releases/download/v3.0/async-profiler-3.0-linux-arm64.tar.gz'
su -l ec2-user -c 'tar xzf /home/ec2-user/async-profiler/async-profiler.tar.gz -C /home/ec2-user/async-profiler --strip-components=1'

# --- Step 11: Setup cron and logrotate ---
systemctl enable crond
systemctl start crond
echo '*/5 * * * * /home/ec2-user/opensearch-test-automation/profiler/profile-opensearch.sh >> /home/ec2-user/profile-cron.log 2>&1' | crontab -u ec2-user -

cat > /etc/logrotate.d/opensearch-profiler << 'LOGROTATE'
/home/ec2-user/datafusion-opensearch-run.log
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
su -l ec2-user -c 'nohup /home/ec2-user/datafusion-opensearch/bin/opensearch > /home/ec2-user/datafusion-opensearch-run.log 2>&1 &'
