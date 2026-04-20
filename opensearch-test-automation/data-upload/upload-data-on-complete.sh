#!/bin/bash
set -eo pipefail

# =============================================================================
# upload-data-on-complete.sh — Polls S3 for benchmark-complete flag, then
# uploads the OpenSearch data folder to S3.
#
# Reads config from ~/.opensearch-env:
#   ENGINE       — "datafusion" or "lucene" (used for S3 path)
#   S3_BUCKET    — S3 bucket name
#
# The OpenSearch home directory is auto-detected based on ENGINE.
#
# Usage: Called as a background process from user-data:
#   nohup bash upload-data-on-complete.sh > ~/upload-data.log 2>&1 &
# =============================================================================

source "$HOME/.opensearch-env"

INSTANCE_ID=$(cat "$HOME/.instance-id" 2>/dev/null || hostname)

# Determine OpenSearch data directory based on engine
if [ "$ENGINE" = "datafusion" ]; then
  DATA_DIR="$HOME/datafusion-opensearch/data"
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
echo "  S3 target: s3://${S3_BUCKET}/data/${ENGINE}/${INSTANCE_ID}/data.tar.gz"
echo "============================================"

echo "Waiting for benchmark-complete flag in S3..."
while true; do
  if aws s3 ls "s3://${S3_BUCKET}/flags/BENCHMARK_COMPLETE" 2>/dev/null; then
    echo "Benchmark complete! Uploading data folder..."
    tar czf /tmp/data.tar.gz -C "$DATA_DIR" .
    aws s3 cp /tmp/data.tar.gz "s3://${S3_BUCKET}/data/${ENGINE}/${INSTANCE_ID}/data.tar.gz"
    rm -f /tmp/data.tar.gz
    echo "Data folder uploaded to s3://${S3_BUCKET}/data/${ENGINE}/${INSTANCE_ID}/data.tar.gz"
    break
  fi
  echo "  Flag not found yet, checking again in 60s..."
  sleep 60
done
