#!/bin/bash
set -euo pipefail

# =============================================================================
# check-field-integrity.sh — Compares field-level null/row counts between
# Lucene (trusted baseline) and DataFusion to verify data integrity.
#
# For each field in the index, queries both engines for:
#   - Total document count
#   - Missing (null) count per field
#
# Outputs a comparison table and JSON report.
#
# Usage:
#   bash check-field-integrity.sh <lucene-host> <datafusion-host> [index-name]
#   bash check-field-integrity.sh 172.31.84.150 internal-OpenSe-Clust-xxx.elb.amazonaws.com
#
# Reads S3_BUCKET from ~/.opensearch-env for uploading results.
# =============================================================================

source "$HOME/.opensearch-env" 2>/dev/null || true

LUCENE_HOST="${1:?Usage: $0 <lucene-host> <datafusion-host> [index-name]}"
DATAFUSION_HOST="${2:?Usage: $0 <lucene-host> <datafusion-host> [index-name]}"
INDEX="${3:-clickbench}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="$HOME/data-integrity-results"
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="$OUTPUT_DIR/field-integrity-${TIMESTAMP}.json"

echo "============================================"
echo "  Field Integrity Check"
echo "  Lucene:     ${LUCENE_HOST}:9200"
echo "  DataFusion: ${DATAFUSION_HOST}:9200"
echo "  Index:      ${INDEX}"
echo "============================================"

# --- Step 1: Get field list from Lucene mapping ---
echo ""
echo "Fetching field mapping from Lucene..."
MAPPING=$(curl -s "http://${LUCENE_HOST}:9200/${INDEX}/_mapping")
FIELDS=$(echo "$MAPPING" | python3 -c "
import sys, json
mapping = json.load(sys.stdin)
# Navigate to properties — handle both flat and nested index key
for idx in mapping:
    props = mapping[idx].get('mappings', {}).get('properties', {})
    for field in sorted(props.keys()):
        print(field)
" 2>/dev/null)

if [ -z "$FIELDS" ]; then
  echo "❌ Could not extract fields from mapping"
  exit 1
fi

FIELD_COUNT=$(echo "$FIELDS" | wc -l | tr -d ' ')
echo "Found ${FIELD_COUNT} fields"

# --- Step 2: Get total doc count from both engines ---
LUCENE_TOTAL=$(curl -s "http://${LUCENE_HOST}:9200/${INDEX}/_count" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
DF_TOTAL=$(curl -s "http://${DATAFUSION_HOST}:9200/${INDEX}/_count" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")

echo "Lucene total docs:     ${LUCENE_TOTAL}"
echo "DataFusion total docs: ${DF_TOTAL}"
echo ""

# --- Step 3: For each field, query missing (null) count ---
echo "Checking each field..."
echo ""
printf "%-30s | %12s | %12s | %12s | %12s | %s\n" "Field" "Lucene Total" "Lucene Nulls" "DF Total" "DF Nulls" "Match?"
printf "%-30s-+-%12s-+-%12s-+-%12s-+-%12s-+-%s\n" "------------------------------" "------------" "------------" "------------" "------------" "------"

PASS_COUNT=0
FAIL_COUNT=0
RESULTS="[]"

while IFS= read -r FIELD; do
  # Query Lucene for missing count
  LUCENE_MISSING=$(curl -s "http://${LUCENE_HOST}:9200/${INDEX}/_search" \
    -H 'Content-Type: application/json' \
    -d "{\"size\":0,\"aggs\":{\"missing_field\":{\"missing\":{\"field\":\"${FIELD}\"}}}}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('aggregations',{}).get('missing_field',{}).get('doc_count',0))" 2>/dev/null || echo "-1")

  # Query DataFusion for missing count
  DF_MISSING=$(curl -s "http://${DATAFUSION_HOST}:9200/${INDEX}/_search" \
    -H 'Content-Type: application/json' \
    -d "{\"size\":0,\"aggs\":{\"missing_field\":{\"missing\":{\"field\":\"${FIELD}\"}}}}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('aggregations',{}).get('missing_field',{}).get('doc_count',0))" 2>/dev/null || echo "-1")

  # Compare
  if [ "$LUCENE_TOTAL" = "$DF_TOTAL" ] && [ "$LUCENE_MISSING" = "$DF_MISSING" ]; then
    MATCH="✅"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    MATCH="❌"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  printf "%-30s | %12s | %12s | %12s | %12s | %s\n" "$FIELD" "$LUCENE_TOTAL" "$LUCENE_MISSING" "$DF_TOTAL" "$DF_MISSING" "$MATCH"

  # Append to JSON results
  RESULTS=$(echo "$RESULTS" | python3 -c "
import sys, json
results = json.load(sys.stdin)
results.append({
    'field': '${FIELD}',
    'lucene_total': ${LUCENE_TOTAL},
    'lucene_nulls': ${LUCENE_MISSING},
    'datafusion_total': ${DF_TOTAL},
    'datafusion_nulls': ${DF_MISSING},
    'match': ${LUCENE_TOTAL} == ${DF_TOTAL} and ${LUCENE_MISSING} == ${DF_MISSING}
})
print(json.dumps(results))
" 2>/dev/null)

done <<< "$FIELDS"

# --- Step 4: Write JSON report ---
echo "$RESULTS" | python3 -c "
import sys, json
results = json.load(sys.stdin)
report = {
    'timestamp': '${TIMESTAMP}',
    'index': '${INDEX}',
    'lucene_host': '${LUCENE_HOST}',
    'datafusion_host': '${DATAFUSION_HOST}',
    'lucene_total_docs': ${LUCENE_TOTAL},
    'datafusion_total_docs': ${DF_TOTAL},
    'total_fields': ${FIELD_COUNT},
    'pass': ${PASS_COUNT},
    'fail': ${FAIL_COUNT},
    'fields': results
}
print(json.dumps(report, indent=2))
" > "$OUTPUT_FILE"

echo ""
echo "============================================"
echo "  Field Integrity Check Complete"
echo "  Total: ${FIELD_COUNT} | Pass: ${PASS_COUNT} | Fail: ${FAIL_COUNT}"
echo "  Output: ${OUTPUT_FILE}"
echo "============================================"

# --- Step 5: Upload to S3 ---
if [ -n "${S3_BUCKET:-}" ]; then
  # Upload JSON
  aws s3 cp "$OUTPUT_FILE" "s3://${S3_BUCKET}/data-integrity/field-integrity-${TIMESTAMP}.json"
  echo "Uploaded JSON: s3://${S3_BUCKET}/data-integrity/field-integrity-${TIMESTAMP}.json"

  # Generate and upload CSV (opens in Excel)
  CSV_FILE="$OUTPUT_DIR/field-integrity-${TIMESTAMP}.csv"
  echo "Field,Lucene_Total,Lucene_Nulls,DataFusion_Total,DataFusion_Nulls,Match" > "$CSV_FILE"
  echo "$RESULTS" | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    print(f\"{r['field']},{r['lucene_total']},{r['lucene_nulls']},{r['datafusion_total']},{r['datafusion_nulls']},{r['match']}\")
" >> "$CSV_FILE"
  aws s3 cp "$CSV_FILE" "s3://${S3_BUCKET}/data-integrity/field-integrity-${TIMESTAMP}.csv"
  echo "Uploaded CSV:  s3://${S3_BUCKET}/data-integrity/field-integrity-${TIMESTAMP}.csv"
fi
