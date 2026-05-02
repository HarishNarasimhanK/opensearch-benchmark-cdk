#!/bin/bash
set -exo pipefail
exec > /var/log/user-data.log 2>&1

# =============================================================================
# user-data-benchmark.sh — Installs OSB, clones scripts repo, runs benchmarks
# =============================================================================

# --- Step 1: Install dependencies ---
yum install -y python3-pip git amazon-cloudwatch-agent

# --- Step 1b: Start CloudWatch agent (streams logs to CloudWatch) ---
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/user-data.log", "log_group_name": "/opensearch/benchmark/user-data", "log_stream_name": "{{RUN_ID}}/{instance_id}-benchmark" },
          { "file_path": "/home/ec2-user/benchmark-run.log", "log_group_name": "/opensearch/benchmark/run", "log_stream_name": "{{RUN_ID}}/{instance_id}-benchmark" },
          { "file_path": "/home/ec2-user/field-integrity.log", "log_group_name": "/opensearch/benchmark/field-integrity", "log_stream_name": "{{RUN_ID}}/{instance_id}-benchmark" },
          { "file_path": "/home/ec2-user/benchmark-lucene.log", "log_group_name": "/opensearch/benchmark/lucene", "log_stream_name": "{{RUN_ID}}/{instance_id}-benchmark" },
          { "file_path": "/home/ec2-user/benchmark-datafusion.log", "log_group_name": "/opensearch/benchmark/datafusion", "log_stream_name": "{{RUN_ID}}/{instance_id}-benchmark" },
          { "file_path": "/home/ec2-user/correctness-lucene.log", "log_group_name": "/opensearch/benchmark/correctness-lucene", "log_stream_name": "{{RUN_ID}}/{instance_id}-benchmark" },
          { "file_path": "/home/ec2-user/correctness-datafusion.log", "log_group_name": "/opensearch/benchmark/correctness-datafusion", "log_stream_name": "{{RUN_ID}}/{instance_id}-benchmark" }
        ]
      }
    }
  }
}
CWCONFIG
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

# --- Step 2: Install OpenSearch Benchmark ---
su -l ec2-user -c 'pip3 install opensearch-benchmark --user'
su -l ec2-user -c 'echo "export PATH=\$HOME/.local/bin:\$PATH" >> ~/.bashrc'

# --- Step 2b: Configure OSB metrics store (for telemetry persistence) ---
METRICS_HOST="{{METRICS_STORE_HOST}}"
if [ -n "$METRICS_HOST" ]; then
  echo "Configuring OSB metrics store: $METRICS_HOST"
  su -l ec2-user -c 'mkdir -p ~/.osb && cat > ~/.osb/benchmark.ini << OSBEOF
[meta]
config.version = 17

[system]
env.name = local

[node]
root.dir = /home/ec2-user/.osb/benchmarks
src.root.dir = /home/ec2-user/.osb/benchmarks/src

[source]
remote.repo.url = https://github.com/opensearch-project/OpenSearch.git
opensearch.src.subdir = OpenSearch

[benchmarks]
local.dataset.cache = /home/ec2-user/.osb/benchmarks/data

[results_publishing]
datastore.type = opensearch
datastore.host = '"${METRICS_HOST}"'
datastore.port = {{METRICS_STORE_PORT}}
datastore.secure = {{METRICS_STORE_SECURE}}
datastore.user =
datastore.password =

[workload]

[driver]

[client]
options =

[telemetry]
devices =
OSBEOF'
  echo "OSB metrics store configured."
else
  echo "No metrics store configured — using in-memory (telemetry data will not persist)."
fi

# --- Step 3: Write env config ---
cat > /home/ec2-user/.opensearch-env << 'ENVEOF'
S3_BUCKET={{S3_PROFILE_BUCKET}}
DATAFUSION_HOST={{DATAFUSION_PRIVATE_IP}}
LUCENE_HOST={{LUCENE_PRIVATE_IP}}
DATA_NODE_COUNT={{DATA_NODE_COUNT}}
RUN_ID={{RUN_ID}}
METRICS_STORE_HOST={{METRICS_STORE_HOST}}
METRICS_STORE_PORT={{METRICS_STORE_PORT}}
METRICS_STORE_SECURE={{METRICS_STORE_SECURE}}
WORKLOAD_PATH_DATAFUSION=/home/ec2-user/datafusion-workloads/clickbench
WORKLOAD_PATH_LUCENE=/home/ec2-user/lucene-workloads/clickbench
ENVEOF
chown ec2-user:ec2-user /home/ec2-user/.opensearch-env

# --- Step 4: Clone repos ---
su -l ec2-user -c 'aws s3 cp {{SCRIPTS_S3_PATH}} /tmp/automation-scripts.zip && mkdir -p /home/ec2-user/opensearch-test-automation && cd /home/ec2-user/opensearch-test-automation && unzip -o /tmp/automation-scripts.zip && chmod +x /home/ec2-user/opensearch-test-automation/**/*.sh && rm /tmp/automation-scripts.zip'
su -l ec2-user -c 'git clone -b {{WORKLOAD_BRANCH}} {{WORKLOAD_REPO}} /home/ec2-user/datafusion-workloads'
su -l ec2-user -c 'git clone https://github.com/opensearch-project/opensearch-benchmark-workloads.git /home/ec2-user/lucene-workloads'

# --- Step 5: Auto-run all benchmarks ---
su -l ec2-user -c 'nohup bash /home/ec2-user/opensearch-test-automation/run-all.sh > /home/ec2-user/benchmark-run.log 2>&1 &'
