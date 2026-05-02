#!/bin/bash
set -euo pipefail

# =============================================================================
# run-all.sh — Orchestrates benchmark + correctness tests for both engines
#
# Generates a RUN_ID (set at deploy time) that all scripts use for S3 paths:
#   s3://bucket/runs/<RUN_ID>/benchmark-results/...
#   s3://bucket/runs/<RUN_ID>/correctness-results/...
#   s3://bucket/runs/<RUN_ID>/data-integrity/...
#   s3://bucket/runs/<RUN_ID>/data/<engine>/<instance-id>/data.tar.gz
#
# Lucene runs first (builds faster — no plugins needed).
# DataFusion runs second (builds slower — needs sandbox plugins + Rust native lib).
#
# Reads config from ~/.opensearch-env:
#   DATAFUSION_HOST              — DataFusion OpenSearch private IP or ALB DNS
#   LUCENE_HOST                  — Lucene OpenSearch private IP or ALB DNS (empty if disabled)
#   WORKLOAD_PATH_DATAFUSION     — Path to datafusion clickbench workload
#   WORKLOAD_PATH_LUCENE         — Path to upstream clickbench workload
#
# Usage: Called automatically by user-data, or manually:
#   bash run-all.sh
# =============================================================================

source "$HOME/.opensearch-env"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR"

# --- Ensure OSB metrics store config exists ---
# benchmark.ini may not exist if user-data failed or OSB hasn't been run yet.
# Write it here to guarantee it's configured before any benchmark runs.
if [ -n "${METRICS_STORE_HOST:-}" ] && ! grep -q "datastore.type = opensearch" ~/.osb/benchmark.ini 2>/dev/null; then
  echo "Configuring OSB metrics store: ${METRICS_STORE_HOST}"
  mkdir -p ~/.osb
  cat > ~/.osb/benchmark.ini << OSBEOF
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
datastore.host = ${METRICS_STORE_HOST}
datastore.port = ${METRICS_STORE_PORT:-443}
datastore.secure = ${METRICS_STORE_SECURE:-True}
datastore.user =
datastore.password =

[workload]

[driver]

[client]
options =

[telemetry]
devices =
OSBEOF
  echo "OSB metrics store configured."
fi

# --- Run ID (set at deploy time, read from .opensearch-env) ---
export RUN_ID

echo "============================================"
echo "  OpenSearch Test Automation"
echo "  Run ID:          ${RUN_ID}"
echo "  Lucene host:     ${LUCENE_HOST:-not enabled} (DSL queries)"
echo "  DataFusion host: ${DATAFUSION_HOST} (PPL queries)"
echo "  S3 prefix:       s3://${S3_BUCKET}/runs/${RUN_ID}/"
echo "============================================"

# --- Clean stale flags from previous runs ---
echo ""
echo "Cleaning stale flags from previous runs..."
aws s3 rm "s3://${S3_BUCKET}/flags/BENCHMARK_COMPLETE" 2>/dev/null || true

# --- Lucene first (builds faster, ready sooner) ---
if [ -n "${LUCENE_HOST:-}" ]; then
  echo ""
  echo ">>> Running Lucene benchmark (DSL queries)..."
  bash "$REPO_DIR/benchmark/run-benchmark.sh" \
    --host "$LUCENE_HOST" \
    --engine lucene \
    --workload "$WORKLOAD_PATH_LUCENE" \
    2>&1 | tee "$HOME/benchmark-lucene.log"

  echo ""
  echo ">>> Running Lucene correctness test (DSL queries)..."
  bash "$REPO_DIR/correctness/run-lucene-correctness-test.sh" "$LUCENE_HOST" "lucene" "$WORKLOAD_PATH_LUCENE/operations/dsl.json" \
    2>&1 | tee "$HOME/correctness-lucene.log"
else
  echo "Lucene instance not enabled, skipping Lucene benchmark and correctness."
fi

# --- DataFusion second (builds slower, needs more time) ---
echo ""
echo ">>> Running DataFusion benchmark (PPL queries)..."
bash "$REPO_DIR/benchmark/run-benchmark.sh" \
  --host "$DATAFUSION_HOST" \
  --engine datafusion \
  --workload "$WORKLOAD_PATH_DATAFUSION" \
  2>&1 | tee "$HOME/benchmark-datafusion.log"

echo ""
echo ">>> Running DataFusion correctness test (PPL queries)..."
bash "$REPO_DIR/correctness/run-datafusion-correctness-test.sh" "$DATAFUSION_HOST" "datafusion" \
  2>&1 | tee "$HOME/correctness-datafusion.log"

echo ""
echo "============================================"
echo "  All tests complete!"
echo "  Benchmark results:    ~/benchmark-results/"
echo "  Correctness results:  ~/correctness-results/"
echo "============================================"

# --- Run field integrity check (data quality comparison) ---
echo ""
echo ">>> Running field integrity check (Lucene vs DataFusion)..."
if [ -n "${LUCENE_HOST:-}" ]; then
  bash "$REPO_DIR/data-integrity/check-field-integrity.sh" "$LUCENE_HOST" "$DATAFUSION_HOST" \
    2>&1 | tee "$HOME/field-integrity.log"
else
  echo "Lucene not enabled, skipping field integrity check."
fi

# --- Signal data nodes to upload their data folders ---
echo ""
echo "Uploading benchmark-complete flag to S3..."
echo "BENCHMARK_COMPLETE=$(date -u +%Y%m%d_%H%M%S)" | aws s3 cp - "s3://${S3_BUCKET}/flags/BENCHMARK_COMPLETE"
echo "Flag uploaded — data nodes will upload their data folders shortly."

echo ""
echo "============================================"
echo "  Run complete: ${RUN_ID}"
echo "  All results at: s3://${S3_BUCKET}/runs/${RUN_ID}/"
echo "============================================"
