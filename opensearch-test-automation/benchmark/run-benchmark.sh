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

# RUN_ID is set at deploy time via .opensearch-env, or generate one for standalone runs
RUN_ID="${RUN_ID:-run-$(date +%Y%m%d_%H%M%S)}"
BENCHMARK_ID="${RUN_ID}-${ENGINE}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
# DataFusion sandbox only supports single shard; Lucene uses 1 shard per data node
if [ "$ENGINE" = "datafusion" ]; then
  NUM_SHARDS=1
else
  NUM_SHARDS="${DATA_NODE_COUNT:-1}"
fi
RESULTS_DIR="$HOME/benchmark-results/${ENGINE}"
mkdir -p "$RESULTS_DIR"

echo "============================================"
echo "  Running ${ENGINE} Benchmark"
echo "  Target: ${OS_HOST}:9200"
echo "  Run ID: ${RUN_ID}"
echo "  Benchmark ID: ${BENCHMARK_ID}"
echo "  Shards: ${NUM_SHARDS} (1 per data node)"
echo "  Test iterations: ${TEST_ITERATIONS:-20}"
echo "  Ingest percentage: ${INGEST_PERCENTAGE:-0.001}"
echo "============================================"

# --- Wait for OpenSearch to be ready ---
echo "Waiting for OpenSearch at ${OS_HOST}:9200..."
for i in $(seq 1 240); do
  if curl -s "http://${OS_HOST}:9200" > /dev/null 2>&1; then
    echo "OpenSearch is responding!"
    break
  fi
  if [ $i -eq 240 ]; then echo "Timed out waiting for OpenSearch after 2 hours"; exit 1; fi
  sleep 30
done

# --- Wait for cluster health to be green ---
echo "Waiting for cluster health to be green..."
for i in $(seq 1 120); do
  STATUS=$(curl -s "http://${OS_HOST}:9200/_cluster/health" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
  if [ "$STATUS" = "green" ]; then
    echo "Cluster health is green!"
    break
  fi
  if [ $i -eq 120 ]; then echo "Timed out waiting for green cluster health after 60 minutes (status: $STATUS)"; exit 1; fi
  echo "  Cluster status: ${STATUS:-not available} (attempt $i/120)"
  sleep 30
done

# --- Select test procedure based on engine ---
if [ "$ENGINE" = "datafusion" ]; then
  TEST_PROCEDURE="datafusion-ppl"
elif [ "$ENGINE" = "lucene" ]; then
  TEST_PROCEDURE="dsl-clickbench"
fi

# --- Run benchmark ---
TELEMETRY_PARAMS='{"node-stats-sample-interval": 5, "node-stats-include-indices": true, "node-stats-include-indices-metrics": "docs,store,indexing,search,merges,segments,query_cache,fielddata,translog"}'

BENCH_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BENCH_START_EPOCH=$(date +%s)
echo ""
echo "-----------------------------------"
echo "[INFO] [${ENGINE}] Benchmark START: ${BENCH_START}"
echo "-----------------------------------"

opensearch-benchmark run \
  --pipeline="benchmark-only" \
  --workload-path="${WORKLOAD_PATH}" \
  --target-hosts="${OS_HOST}:9200" \
  --test-procedure="${TEST_PROCEDURE}" \
  --kill-running-processes \
  --results-format=csv \
  --results-file="${RESULTS_DIR}/${ENGINE}-benchmark-${TIMESTAMP}.csv" \
  --test-run-id="${BENCHMARK_ID}" \
  --show-in-results=all-percentiles \
  --telemetry=node-stats \
  --telemetry-params="${TELEMETRY_PARAMS}" \
  --workload-params="{\"ingest_percentage\": ${INGEST_PERCENTAGE:-0.001}, \"number_of_shards\": ${NUM_SHARDS}, \"number_of_replicas\": 0, \"bulk_indexing_clients\": 1, \"test_iterations\": ${TEST_ITERATIONS:-20}, \"warmup_iterations\": 3}" \
  && OSB_EXIT=0 || OSB_EXIT=$?
BENCH_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BENCH_END_EPOCH=$(date +%s)
BENCH_DURATION=$((BENCH_END_EPOCH - BENCH_START_EPOCH))

echo ""
echo "-----------------------------------"
if [ $OSB_EXIT -eq 0 ]; then
  echo "[INFO] [${ENGINE}] ✅ SUCCESS (took ${BENCH_DURATION} seconds)"
else
  echo "[WARN] [${ENGINE}] ⚠️  FINISHED WITH ERRORS (exit code: ${OSB_EXIT}, took ${BENCH_DURATION} seconds)"
fi
echo "[INFO] [${ENGINE}] Benchmark START: ${BENCH_START}"
echo "[INFO] [${ENGINE}] Benchmark END:   ${BENCH_END}"
echo "[INFO] [${ENGINE}] Duration:        ${BENCH_DURATION}s ($((BENCH_DURATION / 60))m $((BENCH_DURATION % 60))s)"
echo "-----------------------------------"

echo "Results: ${RESULTS_DIR}/${ENGINE}-benchmark-${TIMESTAMP}.csv"

# --- Upload benchmark CSV to S3 ---
if [ -n "${S3_BUCKET:-}" ]; then
  S3_PREFIX="s3://${S3_BUCKET}/runs/${RUN_ID}/benchmark-results/${ENGINE}"
  if aws s3 cp "${RESULTS_DIR}/${ENGINE}-benchmark-${TIMESTAMP}.csv" "${S3_PREFIX}/${ENGINE}-benchmark-${TIMESTAMP}.csv"; then
    echo "Uploaded CSV to: ${S3_PREFIX}/${ENGINE}-benchmark-${TIMESTAMP}.csv"
  else
    echo "Failed to upload CSV to S3."
  fi
fi
