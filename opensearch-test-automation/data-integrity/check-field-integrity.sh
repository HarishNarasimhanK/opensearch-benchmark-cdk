#!/bin/bash
set -euo pipefail

# =============================================================================
# check-field-integrity.sh — Compares field-level data between Lucene and
# Parquet to verify data integrity.
#
# Uses DSL for Lucene (standard path) and PPL for Parquet (because DSL
# doesn't work with the sandbox pluggable dataformat indexes).
#
# Per-field checks:
#   1. Total count  — total docs in the index
#   2. Null count   — docs missing a value for the field
#
# Usage:
#   bash check-field-integrity.sh <lucene-host> <parquet-host> [index-name]
#
# Reads S3_BUCKET from ~/.opensearch-env for uploading results.
# =============================================================================

source "$HOME/.opensearch-env" 2>/dev/null || true

LUCENE_HOST="${1:?Usage: $0 <lucene-host> <parquet-host> [index-name]}"
PARQUET_HOST="${2:?Usage: $0 <lucene-host> <parquet-host> [index-name] [engine-label]}"
INDEX="${3:-clickbench}"
ENGINE_LABEL="${4:-PQ}"
RUN_ID="${RUN_ID:-run-$(date +%Y%m%d_%H%M%S)}"
export ENGINE_LABEL

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="$HOME/data-integrity-results"
mkdir -p "$OUTPUT_DIR"

echo "============================================"
echo "  Field Integrity Check (PPL + DSL)"
echo "  Lucene:     ${LUCENE_HOST}:9200  (DSL)"
echo "  ${ENGINE_LABEL}: ${PARQUET_HOST}:9200  (PPL)"
echo "  Index:      ${INDEX}"
echo "  Run ID:     ${RUN_ID}"
echo "============================================"

export LUCENE_HOST PARQUET_HOST INDEX RUN_ID TIMESTAMP OUTPUT_DIR S3_BUCKET

python3 << 'PYEOF'
import json, subprocess, os, sys

lucene = os.environ["LUCENE_HOST"]
parquet = os.environ["PARQUET_HOST"]
index = os.environ["INDEX"]
run_id = os.environ["RUN_ID"]
timestamp = os.environ["TIMESTAMP"]
output_dir = os.environ["OUTPUT_DIR"]
s3_bucket = os.environ.get("S3_BUCKET", "")

def curl_json(url, method="GET", body=None):
    cmd = ["curl", "-s", "--max-time", "30"]
    if method == "POST":
        cmd += ["-X", "POST"]
    cmd += [url, "-H", "Content-Type: application/json"]
    if body:
        cmd += ["-d", json.dumps(body)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=35)
        return json.loads(r.stdout)
    except:
        return None

def ppl_query(host, query):
    return curl_json(f"http://{host}:9200/_plugins/_ppl", method="POST",
                     body={"query": query})

# --- Step 1: Get field list and types from Lucene mapping ---
print("\nFetching field mapping from Lucene...")
mapping = curl_json(f"http://{lucene}:9200/{index}/_mapping")
if not mapping:
    print("❌ Could not fetch mapping")
    sys.exit(1)

fields = []
for idx in mapping:
    if not isinstance(mapping[idx], dict):
        continue
    props = mapping[idx].get("mappings", {}).get("properties", {})
    for field in sorted(props.keys()):
        ftype = props[field].get("type", "unknown")
        fields.append((field, ftype))

print(f"Found {len(fields)} fields")

# --- Step 2: Get total doc count ---
lucene_count = curl_json(f"http://{lucene}:9200/{index}/_count")
lu_total = lucene_count.get("count", 0) if lucene_count else 0

pq_count = ppl_query(parquet, f"source = {index} | stats count()")
pq_total = pq_count.get("rows", pq_count.get("datarows", [[0]]))[0][0] if pq_count else 0

print(f"Lucene total docs:     {lu_total}")
print(f"Parquet total docs: {pq_total}")
print()

# --- Step 3: Per-field checks ---
print("Running per-field checks...")
print()
header = f"{'Field':<30} | {'Type':<10} | {'LU Total':>8} | {'LU Nulls':>8} | {os.environ.get('ENGINE_LABEL','PQ')+' Total':>8} | {os.environ.get('ENGINE_LABEL','PQ')+' Nulls':>8} | Status"
sep    = f"{'-'*30}-+-{'-'*10}-+-{'-'*8}-+-{'-'*8}-+-{'-'*8}-+-{'-'*8}-+-{'-'*6}"
print(header)
print(sep)

results = []
pass_count = 0
fail_count = 0

for field, ftype in fields:
    # Lucene: DSL missing aggregation
    lu_resp = curl_json(f"http://{lucene}:9200/{index}/_search", method="POST",
                        body={"size": 0, "aggs": {"m": {"missing": {"field": field}}}})
    lu_nulls = lu_resp.get("aggregations", {}).get("m", {}).get("doc_count", -1) if lu_resp else -1

    # Parquet: PPL isnull()
    pq_resp = ppl_query(parquet, f"source = {index} | where isnull({field}) | stats count()")
    pq_nulls = pq_resp.get("rows", pq_resp.get("datarows", [[-1]]))[0][0] if pq_resp and ("rows" in pq_resp or "datarows" in pq_resp) else -1

    match = (lu_total == pq_total) and (lu_nulls == pq_nulls)
    status = "✅" if match else "❌"

    if match:
        pass_count += 1
    else:
        fail_count += 1

    print(f"{field:<30} | {ftype:<10} | {lu_total:>8} | {lu_nulls:>8} | {pq_total:>8} | {pq_nulls:>8} | {status}")

    results.append({
        "field": field,
        "type": ftype,
        "lucene_total": lu_total,
        "lucene_nulls": lu_nulls,
        "parquet_total": pq_total,
        "parquet_nulls": pq_nulls,
        "match": match,
    })

# --- Step 4: Write JSON report ---
report = {
    "timestamp": timestamp,
    "run_id": run_id,
    "index": index,
    "lucene_host": lucene,
    "parquet_host": parquet,
    "query_methods": {
        "lucene": "DSL (_count, missing agg)",
        "parquet": "PPL (stats count(), isnull())",
    },
    "lucene_total_docs": lu_total,
    "parquet_total_docs": pq_total,
    "total_docs_match": lu_total == pq_total,
    "total_fields": len(fields),
    "pass": pass_count,
    "fail": fail_count,
    "fields": results,
}

engine_label = os.environ.get("ENGINE_LABEL", "PQ").lower()

json_file = f"{output_dir}/lucene-vs-{engine_label}-{timestamp}.json"
with open(json_file, "w") as f:
    json.dump(report, f, indent=2)

print()
print("============================================")
print(f"  Field Integrity Check Complete")
print(f"  Total docs:  Lucene={lu_total}  Parquet={pq_total}")
print(f"  Fields:      {len(fields)} total | {pass_count} pass | {fail_count} fail")
print(f"  Output:      {json_file}")
print("============================================")

# --- Step 5: Upload to S3 ---
if s3_bucket:
    s3_prefix = f"s3://{s3_bucket}/runs/{run_id}/data-integrity"

    os.system(f'aws s3 cp "{json_file}" "{s3_prefix}/lucene-vs-{engine_label}-{timestamp}.json"')
    print(f"Uploaded JSON: {s3_prefix}/lucene-vs-{engine_label}-{timestamp}.json")

    csv_file = f"{output_dir}/lucene-vs-{engine_label}-{timestamp}.csv"
    with open(csv_file, "w") as f:
        f.write("Field,Type,Lucene_Total,Lucene_Nulls,Parquet_Total,Parquet_Nulls,Match\n")
        for r in results:
            f.write(f"{r['field']},{r['type']},{r['lucene_total']},{r['lucene_nulls']},{r['parquet_total']},{r['parquet_nulls']},{r['match']}\n")

    os.system(f'aws s3 cp "{csv_file}" "{s3_prefix}/lucene-vs-{engine_label}-{timestamp}.csv"')
    print(f"Uploaded CSV:  {s3_prefix}/lucene-vs-{engine_label}-{timestamp}.csv")

PYEOF
