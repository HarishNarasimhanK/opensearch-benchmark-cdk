#!/bin/bash
set -eo pipefail

# =============================================================================
# profile-opensearch.sh — Captures 60s CPU flamegraph and uploads to S3
#
# Reads config from ~/.opensearch-env:
#   ENGINE       — "parquet" or "lucene" (used for S3 path)
#   S3_BUCKET    — S3 bucket name
#
# Usage: Called by cron every 5 minutes, or manually:
#   bash profiler/profile-opensearch.sh
# =============================================================================

source "$HOME/.opensearch-env"

PROFILER="$HOME/async-profiler/bin/asprof"
OUTPUT_DIR="$HOME/profiles"
mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
INSTANCE_ID=$(cat "$HOME/.instance-id" 2>/dev/null || hostname)
INSTANCE_LABEL="${INSTANCE_ID}"
if [ -n "${NODE_NAME:-}" ]; then
  INSTANCE_LABEL="${INSTANCE_ID}-${NODE_NAME}"
fi

# RUN_ID is set at deploy time, available from .opensearch-env (already sourced)
RUN_ID="${RUN_ID:-unknown-run}"

# Find OpenSearch Java PID (the actual JVM process, not the shell wrapper)
PID=$(pgrep -f 'org.opensearch.bootstrap.OpenSearch' | head -1 || true)
if [ -z "$PID" ]; then
  echo "OpenSearch not running, skipping profile"
  exit 0
fi
echo "Profiling OpenSearch PID: $PID"

FILENAME="wall_${TIMESTAMP}.html"
$PROFILER -d 60 -e wall -t -f "$OUTPUT_DIR/$FILENAME" "$PID"
aws s3 cp "$OUTPUT_DIR/$FILENAME" "s3://${S3_BUCKET}/runs/${RUN_ID}/profiler/${ENGINE}/${INSTANCE_LABEL}/wall/$FILENAME"

# Also capture CPU profile
CPU_FILENAME="cpu_${TIMESTAMP}.html"
$PROFILER -d 60 -e cpu -t -f "$OUTPUT_DIR/$CPU_FILENAME" "$PID"
aws s3 cp "$OUTPUT_DIR/$CPU_FILENAME" "s3://${S3_BUCKET}/runs/${RUN_ID}/profiler/${ENGINE}/${INSTANCE_LABEL}/cpu/$CPU_FILENAME"

# Also capture allocation (memory) profile
ALLOC_FILENAME="alloc_${TIMESTAMP}.html"
$PROFILER -d 60 -e alloc -t -f "$OUTPUT_DIR/$ALLOC_FILENAME" "$PID"
aws s3 cp "$OUTPUT_DIR/$ALLOC_FILENAME" "s3://${S3_BUCKET}/runs/${RUN_ID}/profiler/${ENGINE}/${INSTANCE_LABEL}/alloc/$ALLOC_FILENAME"
