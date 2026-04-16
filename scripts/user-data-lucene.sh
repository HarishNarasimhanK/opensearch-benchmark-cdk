#!/bin/bash
set -exo pipefail
exec > /var/log/user-data.log 2>&1

# =============================================================================
# user-data-lucene.sh — Downloads pre-built Lucene OpenSearch from S3,
# configures it, and starts it. No plugins, DSL queries only.
# =============================================================================

S3_BUCKET="{{S3_PROFILE_BUCKET}}"

# --- Step 1: Install minimal dependencies ---
yum install -y java-21-amazon-corretto-devel cronie amazon-cloudwatch-agent
export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto
echo 'export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto' >> /etc/profile.d/java.sh
sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' >> /etc/sysctl.conf

# --- Step 2: Start CloudWatch agent early ---
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
  "metrics": {
    "namespace": "OpenSearch/Lucene",
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
          { "file_path": "/var/log/user-data.log", "log_group_name": "/opensearch/lucene/user-data", "log_stream_name": "{instance_id}" },
          { "file_path": "/home/ec2-user/lucene-opensearch-run.log", "log_group_name": "/opensearch/lucene/runtime", "log_stream_name": "{instance_id}" }
        ]
      }
    }
  }
}
CWCONFIG
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

# --- Step 3: Wait for builder to finish and upload tar.gz ---
echo "Waiting for Lucene build to be available in S3..."
for i in $(seq 1 120); do
  if su -l ec2-user -c "aws s3 ls s3://${S3_BUCKET}/builds/opensearch-lucene.tar.gz" 2>/dev/null; then
    echo "Lucene tar.gz found in S3!"
    break
  fi
  if [ $i -eq 120 ]; then echo "Timed out waiting for Lucene build after 60 minutes"; exit 1; fi
  echo "  Build not ready yet (attempt $i/120)..."
  sleep 30
done

# --- Step 4: Download and extract pre-built OpenSearch ---
echo "Downloading Lucene OpenSearch from S3..."
su -l ec2-user -c "aws s3 cp s3://${S3_BUCKET}/builds/opensearch-lucene.tar.gz /tmp/opensearch-lucene.tar.gz"
su -l ec2-user -c 'mkdir -p /home/ec2-user/lucene-opensearch && tar xzf /tmp/opensearch-lucene.tar.gz -C /home/ec2-user/lucene-opensearch'
rm -f /tmp/opensearch-lucene.tar.gz
echo "OpenSearch extracted to ~/lucene-opensearch"

# --- Step 5: Configure OpenSearch ---
cat > /home/ec2-user/lucene-opensearch/config/opensearch.yml << 'EOF'
node.name: node-1
cluster.name: lucene-cluster
network.host: _site_
discovery.type: single-node
EOF
chown ec2-user:ec2-user /home/ec2-user/lucene-opensearch/config/opensearch.yml

# --- Step 6: Configure JVM heap ---
sed -i 's/^-Xms.*/-Xms{{JVM_HEAP}}/' /home/ec2-user/lucene-opensearch/config/jvm.options
sed -i 's/^-Xmx.*/-Xmx{{JVM_HEAP}}/' /home/ec2-user/lucene-opensearch/config/jvm.options

# --- Step 7: Write env file and download automation scripts ---
cat > /home/ec2-user/.opensearch-env << 'ENVEOF'
ENGINE=lucene
S3_BUCKET={{S3_PROFILE_BUCKET}}
ENVEOF
chown ec2-user:ec2-user /home/ec2-user/.opensearch-env

su -l ec2-user -c 'aws s3 cp {{SCRIPTS_S3_PATH}} /tmp/automation-scripts.zip && mkdir -p /home/ec2-user/opensearch-test-automation && cd /home/ec2-user/opensearch-test-automation && unzip -o /tmp/automation-scripts.zip && chmod +x /home/ec2-user/opensearch-test-automation/**/*.sh && rm /tmp/automation-scripts.zip'

# --- Step 8: Install async-profiler ---
su -l ec2-user -c 'mkdir -p /home/ec2-user/async-profiler'
su -l ec2-user -c 'curl -L -o /home/ec2-user/async-profiler/async-profiler.tar.gz https://github.com/async-profiler/async-profiler/releases/download/v3.0/async-profiler-3.0-linux-arm64.tar.gz'
su -l ec2-user -c 'tar xzf /home/ec2-user/async-profiler/async-profiler.tar.gz -C /home/ec2-user/async-profiler --strip-components=1'

# --- Step 9: Setup cron and logrotate ---
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

# --- Step 10: Start OpenSearch ---
su -l ec2-user -c 'nohup /home/ec2-user/lucene-opensearch/bin/opensearch > /home/ec2-user/lucene-opensearch-run.log 2>&1 &'
echo "OpenSearch started! Waiting for it to be ready..."
