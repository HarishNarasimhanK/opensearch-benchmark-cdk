#!/bin/bash
set -eo pipefail

# =============================================================================
# upload-data-on-complete.sh — Polls S3 for benchmark-complete flag, then
# uploads the OpenSearch data folder to S3.
#
# Reads config from ~/.opensearch-env:
#   ENGINE       — "parquet" or "lucene" (used for S3 path)
#   S3_BUCKET    — S3 bucket name
#
# The OpenSearch home directory is auto-detected based on ENGINE.
#
# Fixes applied:
#   - Waits for data directory to exist before tarring
#   - Robust instance ID fallback (IMDS → .instance-id file → hostname)
#   - Reads RUN_ID from .opensearch-env (set at deploy time)
#
# Usage: Called as a background process from user-data:
#   nohup bash upload-data-on-complete.sh > ~/upload-data.log 2>&1 &
# =============================================================================

source "$HOME/.opensearch-env"

# Robust instance ID: try .instance-id file, then IMDS, then hostname
INSTANCE_ID=$(cat "$HOME/.instance-id" 2>/dev/null | tr -d '[:space:]')
if [ -z "$INSTANCE_ID" ]; then
  TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)
  INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)
fi
if [ -z "$INSTANCE_ID" ]; then
  INSTANCE_ID=$(hostname)
fi

# Determine OpenSearch data directory based on engine
if [ "$ENGINE" = "parquet" ]; then
  DATA_DIR="$HOME/parquet-opensearch/data"
elif [ "$ENGINE" = "parquetLucene" ]; then
  DATA_DIR="$HOME/parquetLucene-opensearch/data"
elif [ "$ENGINE" = "lucene" ]; then
  DATA_DIR="$HOME/lucene-opensearch/data"
else
  echo "Unknown ENGINE: $ENGINE"
  exit 1
fi

echo "============================================"
echo "  Data Upload Poller"
echo "  Engine: $ENGINE"
echo "  Instance: $INSTANCE_ID"
echo "  Data dir: $DATA_DIR"
echo "============================================"

# --- Wait for benchmark-complete flag ---
# run-all.sh deletes stale BENCHMARK_COMPLETE at the start of each run,
# so by the time this poller starts (after tar.gz download + OpenSearch boot),
# any old flag is already gone.
echo "Waiting for benchmark-complete flag in S3..."
while true; do
  if aws s3 ls "s3://${S3_BUCKET}/flags/BENCHMARK_COMPLETE" 2>/dev/null; then
    echo "Benchmark complete flag detected!"

    # RUN_ID is set at deploy time, available from .opensearch-env (already sourced)
    echo "Run ID: $RUN_ID"
    INSTANCE_LABEL="${INSTANCE_ID}"
    if [ -n "${NODE_NAME:-}" ]; then
      INSTANCE_LABEL="${INSTANCE_ID}-${NODE_NAME}"
    fi
    S3_TARGET="s3://${S3_BUCKET}/runs/${RUN_ID}/data/${ENGINE}/${INSTANCE_LABEL}/data.tar.gz"

    # --- Wait for data directory to exist and have content (infinite poll) ---
    echo "Waiting for data directory to be populated..."
    i=0
    while true; do
      if [ -d "$DATA_DIR" ] && [ "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
        echo "Data directory exists and has content."
        break
      fi
      i=$((i + 1))
      if [ $((i % 20)) -eq 0 ]; then
        echo "  Data dir not ready yet (attempt $i)..."
      fi
      sleep 30
    done

    # --- Wait 30 min for segment merges to complete ---
    echo "Waiting 30 minutes for segment merges to complete..."
    sleep 1800

    # --- Capture storage sizes BEFORE tarring (need live folder structure) ---
    if [ -f "$HOME/opensearch-test-automation/storage-metrics/capture-storage-sizes.sh" ]; then
      echo "Capturing storage sizes..."
      bash "$HOME/opensearch-test-automation/storage-metrics/capture-storage-sizes.sh" || \
        echo "WARNING: Storage size capture failed (non-fatal)"
    fi

    # --- Upload ---
    if [ -d "$DATA_DIR" ] && [ "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
      echo "Tarring data directory..."
      tar czf /tmp/data.tar.gz -C "$DATA_DIR" .
      SIZE=$(du -h /tmp/data.tar.gz | cut -f1)
      echo "Uploading ${SIZE} to S3..."
      aws s3 cp /tmp/data.tar.gz "$S3_TARGET"
      rm -f /tmp/data.tar.gz
      echo "✅ Data folder uploaded to $S3_TARGET"
    else
      echo "❌ Data directory does not exist or is empty: $DATA_DIR"
      echo "   Skipping upload."
    fi
    break
  fi
  echo "  Flag not found yet, checking again in 60s..."
  sleep 60
done
