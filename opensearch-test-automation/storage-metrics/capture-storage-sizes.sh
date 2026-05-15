#!/bin/bash
set -eo pipefail

# =============================================================================
# capture-storage-sizes.sh — Captures shard-level storage sizes after indexing
# completes and uploads a JSON snapshot to S3.
#
# Reports per shard (in bytes):
#   - parquet folder size
#   - lucene index/ folder excluding segments_N files
#   - lucene index/ segments_N files only
#   - translog folder size
#
# Reads config from ~/.opensearch-env (ENGINE, S3_BUCKET, RUN_ID, NODE_NAME).
# Runs once at the end of the benchmark.
# =============================================================================

source "$HOME/.opensearch-env"

INSTANCE_ID=$(cat "$HOME/.instance-id" 2>/dev/null | tr -d '[:space:]')
[ -z "$INSTANCE_ID" ] && INSTANCE_ID=$(hostname)

INSTANCE_LABEL="${INSTANCE_ID}"
[ -n "${NODE_NAME:-}" ] && INSTANCE_LABEL="${INSTANCE_ID}-${NODE_NAME}"

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

if [ ! -d "$DATA_DIR" ]; then
  echo "Data directory not found: $DATA_DIR"
  exit 1
fi

OUTPUT_FILE="/tmp/storage-sizes-${ENGINE}.json"

shopt -s nullglob
SHARDS=("$DATA_DIR"/nodes/*/indices/*/[0-9]*)
shopt -u nullglob

if [ ${#SHARDS[@]} -eq 0 ]; then
  echo "No shard directories found under $DATA_DIR"
  exit 0
fi

echo "============================================"
echo "  Storage Size Capture: ${ENGINE}"
echo "  Instance: ${INSTANCE_LABEL}"
echo "  Found ${#SHARDS[@]} shard(s)"
echo "============================================"

{
  echo "{"
  echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"engine\": \"${ENGINE}\","
  echo "  \"instance\": \"${INSTANCE_LABEL}\","
  echo "  \"run_id\": \"${RUN_ID}\","
  echo "  \"shards\": ["

  first=true
  for shard in "${SHARDS[@]}"; do
    INDEX_UUID=$(basename "$(dirname "$shard")")
    SHARD_NUM=$(basename "$shard")

    PARQUET_BYTES=0
    [ -d "$shard/parquet" ] && PARQUET_BYTES=$(du -sb "$shard/parquet" 2>/dev/null | awk '{print $1}')

    INDEX_TOTAL_BYTES=0
    [ -d "$shard/index" ] && INDEX_TOTAL_BYTES=$(du -sb "$shard/index" 2>/dev/null | awk '{print $1}')

    SEGMENTS_BYTES=0
    if [ -d "$shard/index" ]; then
      SEGMENTS_BYTES=$(find "$shard/index" -maxdepth 1 -type f -name "segments_*" -printf "%s\n" 2>/dev/null | awk '{s+=$1} END {print s+0}')
    fi
    INDEX_NON_SEGMENTS_BYTES=$((INDEX_TOTAL_BYTES - SEGMENTS_BYTES))

    TRANSLOG_BYTES=0
    [ -d "$shard/translog" ] && TRANSLOG_BYTES=$(du -sb "$shard/translog" 2>/dev/null | awk '{print $1}')

    if [ "$first" = true ]; then first=false; else echo ","; fi

    cat <<EOF
    {
      "index_uuid": "${INDEX_UUID}",
      "shard": ${SHARD_NUM},
      "parquet_bytes": ${PARQUET_BYTES},
      "parquet_mb": $(awk "BEGIN {printf \"%.2f\", ${PARQUET_BYTES}/1024/1024}"),
      "parquet_gb": $(awk "BEGIN {printf \"%.3f\", ${PARQUET_BYTES}/1024/1024/1024}"),
      "lucene_excluding_segments_bytes": ${INDEX_NON_SEGMENTS_BYTES},
      "lucene_excluding_segments_mb": $(awk "BEGIN {printf \"%.2f\", ${INDEX_NON_SEGMENTS_BYTES}/1024/1024}"),
      "lucene_excluding_segments_gb": $(awk "BEGIN {printf \"%.3f\", ${INDEX_NON_SEGMENTS_BYTES}/1024/1024/1024}"),
      "lucene_segments_only_bytes": ${SEGMENTS_BYTES},
      "lucene_segments_only_mb": $(awk "BEGIN {printf \"%.2f\", ${SEGMENTS_BYTES}/1024/1024}"),
      "lucene_segments_only_gb": $(awk "BEGIN {printf \"%.3f\", ${SEGMENTS_BYTES}/1024/1024/1024}"),
      "translog_bytes": ${TRANSLOG_BYTES},
      "translog_mb": $(awk "BEGIN {printf \"%.2f\", ${TRANSLOG_BYTES}/1024/1024}"),
      "translog_gb": $(awk "BEGIN {printf \"%.3f\", ${TRANSLOG_BYTES}/1024/1024/1024}")
    }
EOF
  done

  echo ""
  echo "  ]"
  echo "}"
} > "$OUTPUT_FILE"

cat "$OUTPUT_FILE"

S3_TARGET="s3://${S3_BUCKET}/runs/${RUN_ID}/storage-sizes/${ENGINE}/${INSTANCE_LABEL}/storage-sizes.json"
aws s3 cp "$OUTPUT_FILE" "$S3_TARGET"
echo "Uploaded storage sizes to: $S3_TARGET"
