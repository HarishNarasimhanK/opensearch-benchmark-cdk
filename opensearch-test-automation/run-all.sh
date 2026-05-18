#!/bin/bash
set -euo pipefail

# =============================================================================
# run-all.sh — Orchestrates benchmark + correctness tests for all engines
#
# Generates a RUN_ID (set at deploy time) that all scripts use for S3 paths:
#   s3://bucket/runs/<RUN_ID>/benchmark-results/...
#   s3://bucket/runs/<RUN_ID>/correctness-results/...
#   s3://bucket/runs/<RUN_ID>/data-integrity/...
#   s3://bucket/runs/<RUN_ID>/data/<engine>/<instance-id>/data.tar.gz
#
# Parquet runs first, then Lucene, then ParquetLucene.
# All run sequentially — OSB does not allow two instances on the same machine.
#
# Reads config from ~/.opensearch-env:
#   PARQUET_HOST              — Parquet OpenSearch private IP or ALB DNS
#   LUCENE_HOST               — Lucene OpenSearch private IP or ALB DNS (empty if disabled)
#   PARQUET_LUCENE_HOST       — ParquetLucene OpenSearch private IP (empty if disabled)
#   WORKLOAD_PATH_PARQUET     — Path to parquet clickbench workload
#   WORKLOAD_PATH_LUCENE      — Path to upstream clickbench workload
#   WORKLOAD_PATH_PARQUET_LUCENE — Path to parquetLucene clickbench workload
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
echo "  Parquet host:    ${PARQUET_HOST} (PPL queries)"
echo "  ParquetLucene:   ${PARQUET_LUCENE_HOST:-not enabled} (PPL queries, indexed_parquet)"
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
# Parquet runs first, then Lucene, then ParquetLucene.

echo ""
echo ">>> Running Parquet benchmark (PPL queries)..."
bash "$REPO_DIR/benchmark/run-benchmark.sh" \
  --host "$PARQUET_HOST" \
  --engine parquet \
  --workload "$WORKLOAD_PATH_PARQUET" \
  2>&1 | tee "$HOME/benchmark-parquet.log"

echo ""
echo ">>> Running Parquet correctness test..."
bash "$REPO_DIR/correctness/run-parquet-correctness-test.sh" "$PARQUET_HOST" "parquet" \
  2>&1 | tee "$HOME/correctness-parquet.log"

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

if [ -n "${PARQUET_LUCENE_HOST:-}" ]; then
  echo ""
  echo ">>> Running ParquetLucene benchmark (PPL queries, indexed_parquet)..."
  bash "$REPO_DIR/benchmark/run-benchmark.sh" \
    --host "$PARQUET_LUCENE_HOST" \
    --engine parquetLucene \
    --workload "$WORKLOAD_PATH_PARQUET_LUCENE" \
    2>&1 | tee "$HOME/benchmark-parquetLucene.log"

  echo ""
  echo ">>> Running ParquetLucene correctness test..."
  bash "$REPO_DIR/correctness/run-parquet-correctness-test.sh" "$PARQUET_LUCENE_HOST" "parquetLucene" \
    2>&1 | tee "$HOME/correctness-parquetLucene.log"
else
  echo "ParquetLucene instance not enabled, skipping."
fi

echo ""
echo "============================================"
echo "  All tests complete!"
echo "  Benchmark results:    ~/benchmark-results/"
echo "  Correctness results:  ~/correctness-results/"
echo "============================================"

# --- Run field integrity check (data quality comparison) ---
echo ""
echo ">>> Running field integrity check (Lucene vs Parquet)..."
if [ -n "${LUCENE_HOST:-}" ]; then
  bash "$REPO_DIR/data-integrity/check-field-integrity.sh" "$LUCENE_HOST" "$PARQUET_HOST" \
    2>&1 | tee "$HOME/field-integrity.log"
else
  echo "Lucene not enabled, skipping field integrity check."
fi

if [ -n "${LUCENE_HOST:-}" ] && [ -n "${PARQUET_LUCENE_HOST:-}" ]; then
  echo ""
  echo ">>> Running field integrity check (Lucene vs ParquetLucene)..."
  bash "$REPO_DIR/data-integrity/check-field-integrity.sh" "$LUCENE_HOST" "$PARQUET_LUCENE_HOST" \
    2>&1 | tee "$HOME/field-integrity-parquetLucene.log"
fi

# --- Generate comparison visualization ---
echo ""
echo ">>> Generating benchmark comparison dashboard..."
PQ_CSV=$(ls -t "$HOME/benchmark-results/parquet/"*.csv 2>/dev/null | head -1)
LU_CSV=$(ls -t "$HOME/benchmark-results/lucene/"*.csv 2>/dev/null | head -1)
PQL_CSV=$(ls -t "$HOME/benchmark-results/parquetLucene/"*.csv 2>/dev/null | head -1)

if [ -n "$PQ_CSV" ] && [ -n "$LU_CSV" ]; then
  EXTRA_ARGS=""
  if [ -n "$PQL_CSV" ]; then
    EXTRA_ARGS="--parquet-lucene-csv $PQL_CSV"
  fi
  python3 "$REPO_DIR/visualization/generate-comparison.py" \
    --parquet-csv "$PQ_CSV" \
    --lucene-csv "$LU_CSV" \
    $EXTRA_ARGS \
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
  echo "Skipping dashboard — missing benchmark CSVs (PQ=$PQ_CSV, LU=$LU_CSV)"
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
