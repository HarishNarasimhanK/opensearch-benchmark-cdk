#!/bin/bash
set -exo pipefail
exec > /var/log/user-data.log 2>&1

# --- Install dependencies ---
yum install -y python3-pip git

# --- Install OpenSearch Benchmark ---
su -l ec2-user -c 'pip3 install opensearch-benchmark --user'
su -l ec2-user -c 'echo "export PATH=\$HOME/.local/bin:\$PATH" >> ~/.bashrc'

# --- Clone benchmark workloads ---
su -l ec2-user -c 'git clone -b {{WORKLOAD_BRANCH}} {{WORKLOAD_REPO}} /home/ec2-user/osb-workloads'

# --- Write the benchmark run script ---
cat > /home/ec2-user/run-benchmark.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

OS_HOST="${1:-{{OPENSEARCH_PRIVATE_IP}}}"
RUN_ID="${2:-datafusion-$(date +%Y%m%d_%H%M%S)}"
RESULTS_DIR="$HOME/benchmark-results"
mkdir -p "$RESULTS_DIR"

echo "============================================"
echo "  Running Benchmark"
echo "  Target: ${OS_HOST}:9200"
echo "  Run ID: ${RUN_ID}"
echo "============================================"

# Wait for OpenSearch to be ready
echo "Waiting for OpenSearch at ${OS_HOST}:9200..."
for i in $(seq 1 100); do
  if curl -s "http://${OS_HOST}:9200" > /dev/null 2>&1; then
    echo "OpenSearch is ready!"
    break
  fi
  if [ $i -eq 100 ]; then
    echo "Timed out waiting for OpenSearch"
    exit 1
  fi
  sleep 30
done

opensearch-benchmark run \
  --pipeline="benchmark-only" \
  --workload-path=/home/ec2-user/osb-workloads/clickbench \
  --target-hosts="${OS_HOST}:9200" \
  --test-procedure=datafusion-ppl \
  --kill-running-processes \
  --results-format=csv \
  --results-file="${RESULTS_DIR}/${RUN_ID}.csv" \
  --test-run-id="${RUN_ID}" \
  --exclude-tasks="q20-specific-user,q24-google-urls-sorted,q25-search-phrases-by-time,q26-search-phrases-sorted,q27-search-phrases-multi-sort" \
  --workload-params='{"ingest_percentage": 0.001, "number_of_replicas": 0, "bulk_indexing_clients": 1, "test_iterations": 5, "warmup_iterations": 1}'

echo ""
echo "Results: ${RESULTS_DIR}/${RUN_ID}.csv"

# Upload results to S3
S3_BUCKET="{{S3_PROFILE_BUCKET}}"
if aws s3 cp "${RESULTS_DIR}/${RUN_ID}.csv" "s3://${S3_BUCKET}/benchmark-results/${RUN_ID}.csv" 2>/dev/null; then
  echo "Uploaded to: s3://${S3_BUCKET}/benchmark-results/${RUN_ID}.csv"
  echo "Download:    aws s3 cp s3://${S3_BUCKET}/benchmark-results/${RUN_ID}.csv ~/Downloads/"
fi
SCRIPT
chmod +x /home/ec2-user/run-benchmark.sh
chown ec2-user:ec2-user /home/ec2-user/run-benchmark.sh

# --- Auto-run the benchmark ---
su -l ec2-user -c 'nohup bash /home/ec2-user/run-benchmark.sh > /home/ec2-user/benchmark-run.log 2>&1 &'
