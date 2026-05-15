#!/bin/bash
set -exo pipefail
exec > /var/log/user-data.log 2>&1

# =============================================================================
# user-data-parquet.sh — Downloads pre-built Parquet OpenSearch from S3,
# configures it, and starts it with the sandbox feature flags.
#
# The tar.gz already contains:
#   - OpenSearch distribution (localDistro)
#   - 9 plugins (arrow-flight-rpc, analytics-engine, parquet-data-format,
#     analytics-backend-datafusion, analytics-backend-lucene,
#     dsl-query-executor, composite-engine, opensearch-job-scheduler, opensearch-sql)
#   - libopensearch_native.so in lib/
#   - discovery-ec2 plugin (for multi-node)
#
# No build needed — the builder instance handles that.
# =============================================================================

S3_BUCKET="{{S3_PROFILE_BUCKET}}"

# --- Step 1: Install minimal dependencies (no build tools needed) ---
# Cache instance ID early (IMDS may become unavailable later)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || hostname)
echo "$INSTANCE_ID" > /home/ec2-user/.instance-id
chown ec2-user:ec2-user /home/ec2-user/.instance-id
echo "Instance ID: $INSTANCE_ID"

# JDK 25 required for sandbox Parquet (JDK 21 is not sufficient)
echo "=== Installing JDK 25 (Corretto) ==="
su -l ec2-user -c 'wget -q "https://corretto.aws/downloads/resources/25.0.3.9.1/amazon-corretto-25.0.3.9.1-linux-aarch64.tar.gz" -O /tmp/corretto25.tar.gz && tar xzf /tmp/corretto25.tar.gz -C $HOME && rm /tmp/corretto25.tar.gz'
echo 'export JAVA_HOME=$HOME/amazon-corretto-25.0.3.9.1-linux-aarch64' >> /home/ec2-user/.bashrc
echo 'export PATH=$JAVA_HOME/bin:$PATH' >> /home/ec2-user/.bashrc

yum install -y cronie amazon-cloudwatch-agent
sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' >> /etc/sysctl.conf

# --- Step 2: Start CloudWatch agent early ---
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
  "agent": {
    "metrics_collection_interval": 10,
    "run_as_user": "cwagent"
  },
  "metrics": {
    "namespace": "OpenSearch/{{RUN_ID}}",
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}",
      "InstanceType": "${aws:InstanceType}"
    },
    "aggregation_dimensions": [["InstanceId"]],
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_active", "cpu_usage_idle", "cpu_usage_iowait", "cpu_usage_user", "cpu_usage_system", "cpu_usage_steal"]
      },
      "mem": {
        "measurement": ["mem_active", "mem_available", "mem_available_percent", "mem_buffered", "mem_cached", "mem_free", "mem_total", "mem_used", "mem_used_percent"]
      },
      "disk": {
        "measurement": ["disk_free", "disk_used", "disk_used_percent", "disk_total"],
        "drop_device": true
      },
      "diskio": {
        "measurement": ["diskio_read_bytes", "diskio_write_bytes", "diskio_reads", "diskio_writes", "diskio_io_time", "diskio_iops_in_progress"]
      },
      "net": {
        "measurement": ["net_bytes_recv", "net_bytes_sent", "net_packets_recv", "net_packets_sent", "net_err_in", "net_err_out"]
      },
      "swap": {
        "measurement": ["swap_free", "swap_used", "swap_used_percent"]
      },
      "netstat": {
        "measurement": ["netstat_tcp_established", "netstat_tcp_time_wait", "netstat_tcp_close_wait"]
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/user-data.log", "log_group_name": "{{LOG_GROUP_PREFIX}}/parquet/user-data", "log_stream_name": "{{RUN_ID}}/{instance_id}-{{NODE_NAME}}" },
          { "file_path": "/home/ec2-user/parquet-opensearch-run.log", "log_group_name": "{{LOG_GROUP_PREFIX}}/parquet/runtime", "log_stream_name": "{{RUN_ID}}/{instance_id}-{{NODE_NAME}}" },
          { "file_path": "/home/ec2-user/upload-data.log", "log_group_name": "{{LOG_GROUP_PREFIX}}/parquet/upload-data", "log_stream_name": "{{RUN_ID}}/{instance_id}-{{NODE_NAME}}" },
          { "file_path": "/home/ec2-user/profile-cron.log", "log_group_name": "{{LOG_GROUP_PREFIX}}/parquet/profiler", "log_stream_name": "{{RUN_ID}}/{instance_id}-{{NODE_NAME}}" },
          { "file_path": "/home/ec2-user/vmstat.log", "log_group_name": "{{LOG_GROUP_PREFIX}}/parquet/vmstat", "log_stream_name": "{{RUN_ID}}/{instance_id}-{{NODE_NAME}}" }
        ]
      }
    }
  }
}
CWCONFIG
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

# --- Step 3: Wait for builder to finish and upload tar.gz ---
echo "Waiting for Parquet build to be available in S3..."
for i in $(seq 1 120); do
  if su -l ec2-user -c "aws s3 ls s3://${S3_BUCKET}/builds/opensearch-parquet.tar.gz" 2>/dev/null; then
    echo "Parquet tar.gz found in S3!"
    break
  fi
  if [ $i -eq 120 ]; then echo "Timed out waiting for Parquet build after 60 minutes"; exit 1; fi
  echo "  Build not ready yet (attempt $i/120)..."
  sleep 30
done

# --- Step 4: Download and extract pre-built OpenSearch ---
echo "Downloading Parquet OpenSearch from S3..."
su -l ec2-user -c "aws s3 cp s3://${S3_BUCKET}/builds/opensearch-parquet.tar.gz /tmp/opensearch-parquet.tar.gz"
su -l ec2-user -c 'mkdir -p /home/ec2-user/parquet-opensearch && tar xzf /tmp/opensearch-parquet.tar.gz -C /home/ec2-user/parquet-opensearch'
rm -f /tmp/opensearch-parquet.tar.gz
echo "OpenSearch extracted to ~/parquet-opensearch"

# --- Step 5: Configure OpenSearch ---
if [ "{{CLUSTER_MODE}}" = "multi" ]; then
  cat > /home/ec2-user/parquet-opensearch/config/opensearch.yml << 'EOF'
cluster.name: parquet-cluster
network.host: _site_
cluster.initial_cluster_manager_nodes: ["clusterManager-seed"]
discovery.seed_providers: ec2
discovery.ec2.tag.cluster: {{CLUSTER_TAG}}
node.roles: [{{NODE_ROLES}}]
EOF
  if [ "{{NODE_NAME}}" = "clusterManager-seed" ]; then
    echo 'node.name: clusterManager-seed' >> /home/ec2-user/parquet-opensearch/config/opensearch.yml
  fi
else
  cat > /home/ec2-user/parquet-opensearch/config/opensearch.yml << 'EOF'
node.name: node
cluster.name: parquet-cluster
network.host: _site_
discovery.type: single-node
EOF
fi
chown ec2-user:ec2-user /home/ec2-user/parquet-opensearch/config/opensearch.yml

# --- Step 6: Configure JVM heap ---
sed -i 's/^-Xms.*/-Xms{{JVM_HEAP}}/' /home/ec2-user/parquet-opensearch/config/jvm.options
sed -i 's/^-Xmx.*/-Xmx{{JVM_HEAP}}/' /home/ec2-user/parquet-opensearch/config/jvm.options

# --- Step 7: Write env file and download automation scripts ---
cat > /home/ec2-user/.opensearch-env << 'ENVEOF'
ENGINE=parquet
S3_BUCKET={{S3_PROFILE_BUCKET}}
RUN_ID={{RUN_ID}}
NODE_NAME={{NODE_NAME}}
ENVEOF
chown ec2-user:ec2-user /home/ec2-user/.opensearch-env

su -l ec2-user -c 'aws s3 cp {{SCRIPTS_S3_PATH}} /tmp/automation-scripts.zip && mkdir -p /home/ec2-user/opensearch-test-automation && cd /home/ec2-user/opensearch-test-automation && unzip -o /tmp/automation-scripts.zip && chmod +x /home/ec2-user/opensearch-test-automation/**/*.sh && rm /tmp/automation-scripts.zip'

# --- Step 8: Install async-profiler ---
su -l ec2-user -c 'mkdir -p /home/ec2-user/async-profiler'
su -l ec2-user -c 'curl -L -o /home/ec2-user/async-profiler/async-profiler.tar.gz https://github.com/async-profiler/async-profiler/releases/download/v4.4/async-profiler-4.4-linux-arm64.tar.gz'
su -l ec2-user -c 'tar xzf /home/ec2-user/async-profiler/async-profiler.tar.gz -C /home/ec2-user/async-profiler --strip-components=1'

# --- Step 9: Setup cron and logrotate ---
systemctl enable crond
systemctl start crond
echo '*/3 * * * * /home/ec2-user/opensearch-test-automation/profiler/profile-opensearch.sh >> /home/ec2-user/profile-cron.log 2>&1' | crontab -u ec2-user -

cat > /etc/logrotate.d/opensearch-profiler << 'LOGROTATE'
/home/ec2-user/parquet-opensearch-run.log
/home/ec2-user/profile-cron.log
/home/ec2-user/vmstat.log {
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

# --- Step 10: Start OpenSearch with sandbox feature flags ---
# JVM flags required for Parquet sandbox:
#   -Djava.library.path=...  → tells JVM where to find libopensearch_native.so
#   -Dopensearch.experimental.feature.pluggable.dataformat.enabled=true
#     → enables the pluggable dataformat infrastructure at the server level
#   -Dio.netty.* flags → Arrow/Flight memory allocator needs Netty unsafe access on JDK 25
#   --add-opens / --enable-native-access → required for Arrow direct memory on JDK 25
su -l ec2-user -c '
export JAVA_HOME=$HOME/amazon-corretto-25.0.3.9.1-linux-aarch64
export PATH=$JAVA_HOME/bin:$PATH
export OPENSEARCH_JAVA_OPTS="-Djava.library.path=$HOME/parquet-opensearch/lib -Dopensearch.experimental.feature.pluggable.dataformat.enabled=true -Dopensearch.experimental.feature.transport.stream.enabled=true -Dopensearch.pluggable.dataformat.merge.enabled=true -Dio.netty.allocator.numDirectArenas=1 -Dio.netty.noUnsafe=false -Dio.netty.tryUnsafe=true -Dio.netty.tryReflectionSetAccessible=true --add-opens=java.base/java.nio=ALL-UNNAMED --enable-native-access=ALL-UNNAMED -XX:+EnableDynamicAgentLoading"
nohup $HOME/parquet-opensearch/bin/opensearch > $HOME/parquet-opensearch-run.log 2>&1 &
'
echo "OpenSearch started! Waiting for it to be ready..."

# --- Step 10b: Start vmstat logging (memory allocator diagnostics) ---
yum install -y screen
su -l ec2-user -c 'screen -dmS vmstat bash -c "vmstat 1 | awk '\''NR>2 && \$4+0==\$4 {print strftime(\"%Y-%m-%dT%H:%M:%SZ\",systime()),\"free:\"\$4,\"buff:\"\$5,\"cache:\"\$6; fflush()}'\'' | tee -a /home/ec2-user/vmstat.log"'
echo "vmstat logging started in background (screen session: vmstat)"

# --- Step 11: Background poller — uploads data folder to S3 after benchmark completes ---
su -l ec2-user -c 'nohup bash /home/ec2-user/opensearch-test-automation/data-upload/upload-data-on-complete.sh > /home/ec2-user/upload-data.log 2>&1 &'
