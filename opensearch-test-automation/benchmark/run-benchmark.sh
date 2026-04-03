#!/bin/bash
set -euo pipefail

# =============================================================================
# run-benchmark.sh — Runs OSB clickbench benchmark against a target OpenSearch
#
# Usage:
#   bash run-benchmark.sh --host <ip> --engine <name> --workload <path>
#   bash run-benchmark.sh --host 172.31.85.56 --engine datafusion --workload ~/datafusion-workloads/clickbench
#   bash run-benchmark.sh --host 172.31.81.86 --engine lucene --workload ~/lucene-workloads/clickbench
#
# Reads defaults from ~/.opensearch-env if args not provided.
# =============================================================================

source "$HOME/.opensearch-env" 2>/dev/null || true
export PATH="$HOME/.local/bin:$PATH"

# --- Parse arguments ---
OS_HOST=""
ENGINE=""
WORKLOAD_PATH=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --host)     OS_HOST="$2"; shift 2 ;;
    --engine)   ENGINE="$2"; shift 2 ;;
    --workload) WORKLOAD_PATH="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Validate required args
if [ -z "$OS_HOST" ] || [ -z "$ENGINE" ] || [ -z "$WORKLOAD_PATH" ]; then
  echo "Usage: $0 --host <ip> --engine <name> --workload <path>"
  echo "  --host      OpenSearch host IP"
  echo "  --engine    Engine name (datafusion or lucene)"
  echo "  --workload  Path to clickbench workload directory"
  exit 1
fi

RUN_ID="${ENGINE}-$(date +%Y%m%d_%H%M%S)"
RESULTS_DIR="$HOME/benchmark-results/${ENGINE}"
mkdir -p "$RESULTS_DIR"

echo "============================================"
echo "  Running ${ENGINE} Benchmark"
echo "  Target: ${OS_HOST}:9200"
echo "  Run ID: ${RUN_ID}"
echo "============================================"

# --- Wait for OpenSearch to be ready ---
echo "Waiting for OpenSearch at ${OS_HOST}:9200..."
for i in $(seq 1 100); do
  if curl -s "http://${OS_HOST}:9200" > /dev/null 2>&1; then
    echo "OpenSearch is ready!"
    break
  fi
  if [ $i -eq 100 ]; then echo "Timed out waiting for OpenSearch after 50 minutes"; exit 1; fi
  sleep 30
done

# --- Select test procedure and exclude list based on engine ---
TEST_PROCEDURE="clickbench-test"
EXCLUDE_TASKS=""

if [ "$ENGINE" = "datafusion" ]; then
  TEST_PROCEDURE="datafusion-ppl"
  EXCLUDE_TASKS="--exclude-tasks=q20-specific-user,q24-google-urls-sorted,q25-search-phrases-by-time,q26-search-phrases-sorted,q27-search-phrases-multi-sort"
elif [ "$ENGINE" = "lucene" ]; then
  TEST_PROCEDURE="dsl-clickbench-test"
fi

# --- Run benchmark ---
opensearch-benchmark run \
  --pipeline="benchmark-only" \
  --workload-path="${WORKLOAD_PATH}" \
  --target-hosts="${OS_HOST}:9200" \
  --test-procedure="${TEST_PROCEDURE}" \
  --kill-running-processes \
  --results-format=csv \
  --results-file="${RESULTS_DIR}/${RUN_ID}.csv" \
  --test-run-id="${RUN_ID}" \
  ${EXCLUDE_TASKS} \
  --workload-params='{"ingest_percentage": 0.001, "number_of_replicas": 0, "bulk_indexing_clients": 1, "test_iterations": 5, "warmup_iterations": 1}'

echo "Results: ${RESULTS_DIR}/${RUN_ID}.csv"

# --- Upload to S3 ---
if [ -n "${S3_BUCKET:-}" ]; then
  if aws s3 cp "${RESULTS_DIR}/${RUN_ID}.csv" "s3://${S3_BUCKET}/benchmark-results/${ENGINE}/${RUN_ID}.csv"; then
    echo "Uploaded to: s3://${S3_BUCKET}/benchmark-results/${ENGINE}/${RUN_ID}.csv"
  else
    echo "Failed to upload results to S3."
  fi
fi
