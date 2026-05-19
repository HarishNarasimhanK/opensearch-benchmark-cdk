#!/bin/bash
set -exo pipefail
exec > /var/log/user-data.log 2>&1

# =============================================================================
# user-data-benchmark.sh — Installs OSB, clones scripts repo, runs benchmarks
# =============================================================================

# --- Step 1: Install dependencies ---
yum install -y python3-pip git amazon-cloudwatch-agent

# --- Step 1b: Start CloudWatch agent (streams logs to CloudWatch) ---
# Pre-create log files WITH initial content and correct permissions.
# CW agent (runs as cwagent) needs: file exists + readable + non-empty.
# Also make home dir traversable by cwagent user.
chmod 755 /home/ec2-user
for f in benchmark-run.log benchmark-parquet.log benchmark-lucene.log benchmark-parquetLucene.log; do
  echo "[init] Log file created at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /home/ec2-user/$f
  chown ec2-user:ec2-user /home/ec2-user/$f
  chmod 644 /home/ec2-user/$f
done

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/user-data.log", "log_group_name": "{{LOG_GROUP_PREFIX}}/benchmark/user-data", "log_stream_name": "{{RUN_ID}}/{instance_id}-benchmark" },
          { "file_path": "/home/ec2-user/benchmark-run.log", "log_group_name": "{{LOG_GROUP_PREFIX}}/benchmark/run", "log_stream_name": "{{RUN_ID}}/{instance_id}-benchmark" },
          { "file_path": "/home/ec2-user/benchmark-parquet.log", "log_group_name": "{{LOG_GROUP_PREFIX}}/benchmark/parquet", "log_stream_name": "{{RUN_ID}}/{instance_id}-benchmark" },
          { "file_path": "/home/ec2-user/benchmark-lucene.log", "log_group_name": "{{LOG_GROUP_PREFIX}}/benchmark/lucene", "log_stream_name": "{{RUN_ID}}/{instance_id}-benchmark" },
          { "file_path": "/home/ec2-user/benchmark-parquetLucene.log", "log_group_name": "{{LOG_GROUP_PREFIX}}/benchmark/parquetLucene", "log_stream_name": "{{RUN_ID}}/{instance_id}-benchmark" }
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

# --- Step 2b: OSB metrics store config ---
# benchmark.ini is written by run-benchmark.sh right before each OSB run.
# This avoids OSB overwriting it during pip install or first invocation.
METRICS_HOST="{{METRICS_STORE_HOST}}"
if [ -n "$METRICS_HOST" ]; then
  echo "OSB metrics store will be configured at benchmark time: $METRICS_HOST"
else
  echo "No metrics store configured — using in-memory (telemetry data will not persist)."
fi

# --- Step 3: Write env config ---
cat > /home/ec2-user/.opensearch-env << 'ENVEOF'
S3_BUCKET={{S3_PROFILE_BUCKET}}
PARQUET_HOST={{PARQUET_PRIVATE_IP}}
LUCENE_HOST={{LUCENE_PRIVATE_IP}}
PARQUET_LUCENE_HOST={{PARQUET_LUCENE_PRIVATE_IP}}
DATA_NODE_COUNT={{DATA_NODE_COUNT}}
RUN_ID={{RUN_ID}}
METRICS_STORE_HOST={{METRICS_STORE_HOST}}
METRICS_STORE_PORT={{METRICS_STORE_PORT}}
METRICS_STORE_SECURE={{METRICS_STORE_SECURE}}
TEST_ITERATIONS={{TEST_ITERATIONS}}
INGEST_PERCENTAGE={{INGEST_PERCENTAGE}}
WORKLOAD_PATH_PARQUET=/home/ec2-user/parquet-workloads/clickbench
WORKLOAD_PATH_LUCENE=/home/ec2-user/lucene-workloads/clickbench
WORKLOAD_PATH_PARQUET_LUCENE=/home/ec2-user/parquetLucene-workloads/clickbench
ENVEOF
chown ec2-user:ec2-user /home/ec2-user/.opensearch-env

# --- Step 4: Clone repos ---
su -l ec2-user -c 'aws s3 cp {{SCRIPTS_S3_PATH}} /tmp/automation-scripts.zip && mkdir -p /home/ec2-user/opensearch-test-automation && cd /home/ec2-user/opensearch-test-automation && unzip -o /tmp/automation-scripts.zip && chmod +x /home/ec2-user/opensearch-test-automation/**/*.sh && rm /tmp/automation-scripts.zip'
su -l ec2-user -c 'git clone -b {{PARQUET_WORKLOAD_BRANCH}} {{PARQUET_WORKLOAD_REPO}} /home/ec2-user/parquet-workloads'
su -l ec2-user -c 'git clone -b {{LUCENE_WORKLOAD_BRANCH}} {{LUCENE_WORKLOAD_REPO}} /home/ec2-user/lucene-workloads'
su -l ec2-user -c 'git clone -b {{PARQUET_LUCENE_WORKLOAD_BRANCH}} {{PARQUET_LUCENE_WORKLOAD_REPO}} /home/ec2-user/parquetLucene-workloads'

# --- Step 4b: Pre-download corpus (DISABLED — see FUTURE-ADDITIONS.md item 4) ---
# Uncomment to warm the OSB cache with a local throwaway OpenSearch.
# Currently disabled because gradlew run is slow on m7g.medium.
# Better approach: download the pre-built Lucene tar.gz from S3 instead.
#
# echo "=== Pre-downloading corpus data ==="
# yum install -y java-21-amazon-corretto-devel tar gzip
#
# su -l ec2-user -c '
# set -exo pipefail
# export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto
# export PATH=$JAVA_HOME/bin:$HOME/.local/bin:$PATH
#
# echo "Cloning OpenSearch for local throwaway instance..."
# git clone --depth 1 https://github.com/opensearch-project/OpenSearch.git $HOME/opensearch-cache-warm
#
# echo "Starting local OpenSearch via gradlew run..."
# cd $HOME/opensearch-cache-warm
# nohup ./gradlew run -x javadoc -x test -x missingJavadoc > $HOME/cache-warm-opensearch.log 2>&1 &
# GRADLE_PID=$!
#
# echo "Waiting for local OpenSearch to start on localhost:9200..."
# for i in $(seq 1 120); do
#   if curl -s "http://localhost:9200" > /dev/null 2>&1; then
#     echo "Local OpenSearch is up!"
#     break
#   fi
#   if [ $i -eq 120 ]; then echo "Timed out waiting for local OpenSearch"; kill $GRADLE_PID 2>/dev/null || true; exit 0; fi
#   sleep 5
# done
#
# echo "Running dummy OSB to trigger corpus download..."
# opensearch-benchmark run \
#   --pipeline="benchmark-only" \
#   --workload-path="$HOME/lucene-workloads/clickbench" \
#   --target-hosts="localhost:9200" \
#   --test-procedure="dsl-clickbench-test" \
#   --kill-running-processes \
#   --workload-params='"'"'{"ingest_percentage": 0, "number_of_shards": 1, "number_of_replicas": 0, "bulk_indexing_clients": 1, "test_iterations": 1, "warmup_iterations": 0}'"'"' \
#   --test-run-id="cache-warm" \
#   || true
#
# echo "Corpus cached at: ~/.osb/benchmarks/data/"
# echo "Killing local OpenSearch..."
# kill $GRADLE_PID 2>/dev/null || true
# sleep 2
# pkill -f "opensearch-cache-warm" 2>/dev/null || true
# pkill -f "GradleDaemon" 2>/dev/null || true
# sleep 3
# kill -9 $GRADLE_PID 2>/dev/null || true
# pkill -9 -f "opensearch-cache-warm" 2>/dev/null || true
#
# echo "Cleaning up throwaway OpenSearch source..."
# rm -rf $HOME/opensearch-cache-warm $HOME/cache-warm-opensearch.log
# echo "Corpus pre-download complete!"
# '

# --- Step 5: Auto-run all benchmarks ---
su -l ec2-user -c 'nohup bash /home/ec2-user/opensearch-test-automation/run-all.sh > /home/ec2-user/benchmark-run.log 2>&1 &'
