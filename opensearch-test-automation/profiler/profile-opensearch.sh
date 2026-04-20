#!/bin/bash
set -eo pipefail

# =============================================================================
# profile-opensearch.sh — Captures 60s CPU flamegraph and uploads to S3
#
# Reads config from ~/.opensearch-env:
#   ENGINE       — "datafusion" or "lucene" (used for S3 path)
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

# Find OpenSearch Java PID (the actual JVM process, not the shell wrapper)
PID=$(pgrep -f 'org.opensearch.bootstrap.OpenSearch' | head -1 || true)
if [ -z "$PID" ]; then
  echo "OpenSearch not running, skipping profile"
  exit 0
fi
echo "Profiling OpenSearch PID: $PID"

FILENAME="cpu_${TIMESTAMP}.html"
$PROFILER -d 60 -f "$OUTPUT_DIR/$FILENAME" "$PID"
aws s3 cp "$OUTPUT_DIR/$FILENAME" "s3://${S3_BUCKET}/profiler/${ENGINE}/${INSTANCE_ID}/$FILENAME"
