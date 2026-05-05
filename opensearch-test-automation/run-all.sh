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
# DataFusion runs first, Lucene runs second.
# Both run sequentially — OSB does not allow two instances on the same machine.
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

# --- Ensure OSB metrics store config ---
# benchmark.ini is written by run-benchmark.sh right before each OSB run.
# No need to write it here.

# --- Run ID (set at deploy time, read from .opensearch-env) ---
export RUN_ID

echo "============================================"
echo "  OpenSearch Test Automation"
echo "  Run ID:          ${RUN_ID}"
echo "  Lucene host:     ${LUCENE_HOST:-not enabled} (DSL queries)"
echo "  DataFusion host: ${DATAFUSION_HOST} (PPL queries)"
echo "  S3 prefix:       s3://${S3_BUCKET}/runs/${RUN_ID}/"
echo "============================================"

ORCHESTRATOR_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ORCHESTRATOR_START_EPOCH=$(date +%s)
echo "[INFO] Orchestrator start: ${ORCHESTRATOR_START}"

# --- Clean stale flags from previous runs ---
echo ""
echo "Cleaning stale flags from previous runs..."
aws s3 rm "s3://${S3_BUCKET}/flags/BENCHMARK_COMPLETE" 2>/dev/null || true

# --- Run benchmarks + correctness sequentially ---
# OSB does not allow two instances on the same machine.
# Lucene runs first, then DataFusion.

if [ -n "${LUCENE_HOST:-}" ]; then
  echo ""
  echo ">>> Running Lucene benchmark (DSL queries)..."
  bash "$REPO_DIR/benchmark/run-benchmark.sh" \
    --host "$LUCENE_HOST" \
    --engine lucene \
    --workload "$WORKLOAD_PATH_LUCENE" \
    2>&1 | tee "$HOME/benchmark-lucene.log"

  echo ""
  echo ">>> Running Lucene correctness test..."
  bash "$REPO_DIR/correctness/run-lucene-correctness-test.sh" "$LUCENE_HOST" "lucene" "$WORKLOAD_PATH_LUCENE/operations/dsl.json" \
    2>&1 | tee "$HOME/correctness-lucene.log"
else
  echo "Lucene instance not enabled, skipping."
fi

echo ""
echo ">>> Running DataFusion benchmark (PPL queries)..."
bash "$REPO_DIR/benchmark/run-benchmark.sh" \
  --host "$DATAFUSION_HOST" \
  --engine datafusion \
  --workload "$WORKLOAD_PATH_DATAFUSION" \
  2>&1 | tee "$HOME/benchmark-datafusion.log"

echo ""
echo ">>> Running DataFusion correctness test..."
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

# --- Generate comparison visualization ---
echo ""
echo ">>> Generating benchmark comparison dashboard..."
DF_CSV=$(ls -t "$HOME/benchmark-results/datafusion/"*.csv 2>/dev/null | head -1)
LU_CSV=$(ls -t "$HOME/benchmark-results/lucene/"*.csv 2>/dev/null | head -1)

if [ -n "$DF_CSV" ] && [ -n "$LU_CSV" ]; then
  python3 "$REPO_DIR/visualization/generate-comparison.py" \
    --datafusion-csv "$DF_CSV" \
    --lucene-csv "$LU_CSV" \
    --output "$HOME/benchmark-comparison.html" \
    --run-id "$RUN_ID" \
    2>&1 | tee "$HOME/visualization.log"

  # Upload to S3
  if [ -f "$HOME/benchmark-comparison.html" ]; then
    aws s3 cp "$HOME/benchmark-comparison.html" \
      "s3://${S3_BUCKET}/runs/${RUN_ID}/benchmark-results/benchmark-comparison.html"
    echo "Dashboard uploaded to: s3://${S3_BUCKET}/runs/${RUN_ID}/benchmark-results/benchmark-comparison.html"
  fi
else
  echo "Skipping dashboard — missing benchmark CSVs (DF=$DF_CSV, LU=$LU_CSV)"
fi

# --- Signal data nodes to upload their data folders ---
echo ""
echo "Uploading benchmark-complete flag to S3..."
echo "BENCHMARK_COMPLETE=$(date -u +%Y%m%d_%H%M%S)" | aws s3 cp - "s3://${S3_BUCKET}/flags/BENCHMARK_COMPLETE"
echo "Flag uploaded — data nodes will upload their data folders shortly."

echo ""
echo "============================================"
ORCHESTRATOR_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ORCHESTRATOR_END_EPOCH=$(date +%s)
ORCHESTRATOR_DURATION=$((ORCHESTRATOR_END_EPOCH - ORCHESTRATOR_START_EPOCH))
echo "  Run complete: ${RUN_ID}"
echo "  All results at: s3://${S3_BUCKET}/runs/${RUN_ID}/"
echo "  Start: ${ORCHESTRATOR_START}"
echo "  End:   ${ORCHESTRATOR_END}"
echo "  Total: ${ORCHESTRATOR_DURATION}s ($((ORCHESTRATOR_DURATION / 60))m $((ORCHESTRATOR_DURATION % 60))s)"
echo "============================================"
