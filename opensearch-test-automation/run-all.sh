#!/bin/bash
set -euo pipefail

# =============================================================================
# run-all.sh — Orchestrates benchmark + correctness tests for both engines
#
# Lucene runs first (builds faster — no plugins needed).
# DataFusion runs second (builds slower — needs SQL + DataFusion plugins).
#
# Lucene:     DSL queries (via /_search)
# DataFusion: PPL queries (via /_plugins/_ppl)
#
# Reads config from ~/.opensearch-env:
#   DATAFUSION_HOST              — DataFusion OpenSearch private IP
#   LUCENE_HOST                  — Lucene OpenSearch private IP (empty if disabled)
#   WORKLOAD_PATH_DATAFUSION     — Path to datafusion clickbench workload (with optimized.enabled)
#   WORKLOAD_PATH_LUCENE         — Path to upstream clickbench workload (vanilla)
#
# Usage: Called automatically by user-data, or manually:
#   bash run-all.sh
# =============================================================================

source "$HOME/.opensearch-env"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR"

echo "============================================"
echo "  OpenSearch Test Automation"
echo "  Lucene host:     ${LUCENE_HOST:-not enabled} (DSL queries)"
echo "  DataFusion host: ${DATAFUSION_HOST} (PPL queries)"
echo "============================================"

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
