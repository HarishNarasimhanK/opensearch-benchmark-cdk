#!/bin/bash
set -euo pipefail

# =============================================================================
# fetch-results.sh — Downloads benchmark results from S3 for a given run ID,
# organizes them locally, and opens the comparison dashboard.
#
# Usage:
#   ./scripts/fetch-results.sh <run-id>
#   ./scripts/fetch-results.sh run-20260519_143022
#   ./scripts/fetch-results.sh              # auto-detects latest run from cdk-outputs.json
#
# What it downloads (minimal, no large data tarballs):
#   - benchmark-results/  (CSVs + comparison HTML)
#   - correctness-results/
#   - data-integrity/
#   - profiles/           (flamegraphs)
#
# Skips:
#   - data/ folder (large tar.gz of OpenSearch data directories — multi-GB)
#
# Output structure:
#   ./results/<run-id>/
#     ├── benchmark-results/
#     │   ├── parquet/        ← CSV files
#     │   ├── lucene/         ← CSV files
#     │   ├── parquetLucene/  ← CSV files
#     │   └── benchmark-comparison.html
#     ├── correctness-results/
#     ├── data-integrity/
#     └── profiles/
#         ├── parquet/        ← flamegraphs (SVG/HTML)
#         └── lucene/
# =============================================================================

source "$(cd "$(dirname "$0")/.." && pwd)/.env"

# --- Determine run ID ---
RUN_ID="${1:-}"

if [ -z "$RUN_ID" ]; then
  # Try to auto-detect from cdk-outputs.json
  CDK_OUTPUTS="$(cd "$(dirname "$0")/.." && pwd)/cdk-outputs.json"
  if [ -f "$CDK_OUTPUTS" ]; then
    RUN_ID=$(jq -r '.[].RunID // .[].F1_RunID // empty' "$CDK_OUTPUTS" 2>/dev/null | head -1)
  fi
fi

if [ -z "$RUN_ID" ]; then
  echo "❌ Usage: $0 <run-id>"
  echo ""
  echo "   Examples:"
  echo "     $0 run-20260519_143022"
  echo "     $0 nightly-run-20260519_000000"
  echo ""
  echo "   Or deploy first (cdk-outputs.json provides the run ID automatically)."
  echo ""
  echo "   List recent runs:"
  echo "     aws s3 ls s3://${S3_BUCKET}/runs/ | tail -10"
  exit 1
fi

S3_PREFIX="s3://${S3_BUCKET}/runs/${RUN_ID}"
LOCAL_DIR="$(pwd)/results/${RUN_ID}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Fetching Benchmark Results from S3                ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Run ID:   ${RUN_ID}"
echo "║  S3 path:  ${S3_PREFIX}/"
echo "║  Local:    ${LOCAL_DIR}/"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# --- Check if run exists ---
echo "🔍 Checking if run exists in S3..."
if ! aws s3 ls "${S3_PREFIX}/" > /dev/null 2>&1; then
  echo "❌ Run not found: ${S3_PREFIX}/"
  echo ""
  echo "   Available runs:"
  aws s3 ls "s3://${S3_BUCKET}/runs/" 2>/dev/null | tail -20 | awk '{print "     " $2}' | sed 's|/$||'
  exit 1
fi
echo "   ✅ Run found!"
echo ""

# --- Create local directory ---
mkdir -p "$LOCAL_DIR"

# --- Download benchmark results (CSVs + HTML) ---
echo "📊 Downloading benchmark results..."
aws s3 sync "${S3_PREFIX}/benchmark-results/" "${LOCAL_DIR}/benchmark-results/" \
  --exclude "*.tar.gz" --quiet 2>/dev/null || true
echo "   ✅ Done"

# --- Download correctness results ---
echo "✅ Downloading correctness results..."
aws s3 sync "${S3_PREFIX}/correctness-results/" "${LOCAL_DIR}/correctness-results/" \
  --quiet 2>/dev/null || true
echo "   ✅ Done"

# --- Download data integrity results ---
echo "🔬 Downloading data integrity results..."
aws s3 sync "${S3_PREFIX}/data-integrity/" "${LOCAL_DIR}/data-integrity/" \
  --quiet 2>/dev/null || true
echo "   ✅ Done"

# --- Download profiles (flamegraphs only, skip raw perf data) ---
echo "🔥 Downloading profiler flamegraphs..."
aws s3 sync "${S3_PREFIX}/profiles/" "${LOCAL_DIR}/profiles/" \
  --exclude "*.jfr" --exclude "*.perf" --exclude "*.collapsed" \
  --quiet 2>/dev/null || true
echo "   ✅ Done"

# --- Download storage metrics if available ---
echo "💾 Downloading storage metrics..."
aws s3 sync "${S3_PREFIX}/storage-metrics/" "${LOCAL_DIR}/storage-metrics/" \
  --quiet 2>/dev/null || true
echo "   ✅ Done"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Download Complete!                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# --- List what we got ---
echo "📁 Local file structure:"
echo "   ${LOCAL_DIR}/"
if [ -d "${LOCAL_DIR}/benchmark-results" ]; then
  echo "   ├── benchmark-results/"
  for engine_dir in "${LOCAL_DIR}/benchmark-results"/*/; do
    if [ -d "$engine_dir" ]; then
      engine=$(basename "$engine_dir")
      echo "   │   ├── ${engine}/"
      for csv in "$engine_dir"*.csv; do
        [ -f "$csv" ] && echo "   │   │   └── $(basename "$csv")"
      done
    fi
  done
  [ -f "${LOCAL_DIR}/benchmark-results/benchmark-comparison.html" ] && \
    echo "   │   └── benchmark-comparison.html"
fi
[ -d "${LOCAL_DIR}/correctness-results" ] && echo "   ├── correctness-results/"
[ -d "${LOCAL_DIR}/data-integrity" ] && echo "   ├── data-integrity/"
[ -d "${LOCAL_DIR}/profiles" ] && echo "   ├── profiles/"
[ -d "${LOCAL_DIR}/storage-metrics" ] && echo "   └── storage-metrics/"
echo ""

# --- Print CSV file paths ---
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📈 Benchmark CSV Files:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
PQ_CSV=""; LU_CSV=""; PQL_CSV=""
for csv in "${LOCAL_DIR}/benchmark-results/parquet/"*.csv; do
  [ -f "$csv" ] && echo "   Parquet:        $csv" && PQ_CSV="$csv"
done
for csv in "${LOCAL_DIR}/benchmark-results/lucene/"*.csv; do
  [ -f "$csv" ] && echo "   Lucene:         $csv" && LU_CSV="$csv"
done
for csv in "${LOCAL_DIR}/benchmark-results/parquetLucene/"*.csv; do
  [ -f "$csv" ] && echo "   ParquetLucene:  $csv" && PQL_CSV="$csv"
done
if [ -z "$PQ_CSV" ] && [ -z "$LU_CSV" ]; then
  echo "   (no CSV files found yet — benchmark may still be running)"
fi
echo ""

# --- Print profile paths ---
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔥 Profiler Flamegraphs:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
PROFILE_COUNT=0
for svg in "${LOCAL_DIR}/profiles/"**/*.{svg,html} 2>/dev/null; do
  if [ -f "$svg" ]; then
    echo "   $svg"
    PROFILE_COUNT=$((PROFILE_COUNT + 1))
  fi
done
if [ "$PROFILE_COUNT" -eq 0 ]; then
  echo "   (no flamegraphs found — profiler may not have run yet)"
fi
echo ""
echo "   To view a flamegraph in your browser:"
echo "     open ${LOCAL_DIR}/profiles/<engine>/<filename>.html"
echo ""

# --- Open comparison dashboard ---
DASHBOARD="${LOCAL_DIR}/benchmark-results/benchmark-comparison.html"
if [ -f "$DASHBOARD" ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🌐 Opening comparison dashboard in browser..."
  echo "   ${DASHBOARD}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if command -v open &> /dev/null; then
    open "$DASHBOARD"
  elif command -v xdg-open &> /dev/null; then
    xdg-open "$DASHBOARD"
  else
    echo "   (could not auto-open — open the file manually in a browser)"
  fi
else
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "⚠️  No comparison dashboard found."
  echo "   The benchmark may still be running. Re-run this script later:"
  echo "     ./scripts/fetch-results.sh ${RUN_ID}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "💡 Quick Commands:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "   View dashboard:"
echo "     open ${DASHBOARD:-${LOCAL_DIR}/benchmark-results/benchmark-comparison.html}"
echo ""
echo "   View flamegraphs:"
echo "     open ${LOCAL_DIR}/profiles/"
echo ""
echo "   Re-generate dashboard locally (if you have new CSVs):"
if [ -n "$PQ_CSV" ] && [ -n "$LU_CSV" ]; then
  REGEN_CMD="python3 opensearch-test-automation/visualization/generate-comparison.py --parquet-csv ${PQ_CSV} --lucene-csv ${LU_CSV}"
  [ -n "$PQL_CSV" ] && REGEN_CMD="${REGEN_CMD} --parquet-lucene-csv ${PQL_CSV}"
  REGEN_CMD="${REGEN_CMD} --output ${LOCAL_DIR}/benchmark-comparison-local.html --run-id ${RUN_ID}"
  echo "     ${REGEN_CMD}"
else
  echo "     (CSVs not yet available)"
fi
echo ""
echo "   List all runs in S3:"
echo "     aws s3 ls s3://${S3_BUCKET}/runs/"
echo ""
echo "   Fetch raw data tarballs (large! only if needed):"
echo "     aws s3 sync ${S3_PREFIX}/data/ ${LOCAL_DIR}/data/"
echo ""
