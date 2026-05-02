#!/bin/bash
set -euo pipefail

# =============================================================================
# run-dsl-correctness-test.sh — Runs all DSL queries and captures raw responses
#
# Usage:
#   bash correctness/run-dsl-correctness-test.sh <host> <engine-name> <workload-dsl-json>
#   bash correctness/run-dsl-correctness-test.sh 172.31.85.175 lucene ~/lucene-workloads/clickbench/operations/dsl.json
#
# Reads S3_BUCKET from ~/.opensearch-env
# =============================================================================

source "$HOME/.opensearch-env" 2>/dev/null || true

OS_HOST="${1:?Usage: $0 <host> <engine-name> <workload-dsl-json>}"
ENGINE="${2:?Usage: $0 <host> <engine-name> <workload-dsl-json>}"
DSL_FILE="${3:?Usage: $0 <host> <engine-name> <workload-dsl-json>}"
RUN_ID="${RUN_ID:-run-$(date +%Y%m%d_%H%M%S)}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="$HOME/correctness-results/${ENGINE}"
OUTPUT_FILE="${RESULTS_DIR}/${ENGINE}-correctness-${TIMESTAMP}.json"
mkdir -p "$RESULTS_DIR"

echo "============================================"
echo "  DSL Correctness Test: ${ENGINE}"
echo "  Target: ${OS_HOST}:9200"
echo "  DSL file: ${DSL_FILE}"
echo "  Output: ${OUTPUT_FILE}"
echo "============================================"

# --- Wait for OpenSearch to be ready ---
echo "Waiting for OpenSearch at ${OS_HOST}:9200..."
for i in $(seq 1 100); do
  if curl -s "http://${OS_HOST}:9200" > /dev/null 2>&1; then
    echo "OpenSearch is ready!"
    break
  fi
  if [ $i -eq 100 ]; then echo "Timed out waiting for OpenSearch"; exit 1; fi
  sleep 30
done

# --- Run queries via Python (DSL bodies are complex JSON, easier to handle in Python) ---
export OS_HOST ENGINE DSL_FILE OUTPUT_FILE S3_BUCKET TIMESTAMP RUN_ID

python3 << 'PYEOF'
import json, subprocess, os, time

host = os.environ["OS_HOST"]
engine = os.environ["ENGINE"]
dsl_file = os.environ["DSL_FILE"]
output_file = os.environ["OUTPUT_FILE"]
s3_bucket = os.environ.get("S3_BUCKET", "")
timestamp = os.environ["TIMESTAMP"]
run_id = os.environ.get("RUN_ID", "unknown")
index = "clickbench"

# Read DSL file — it's a comma-separated list of JSON objects (not a proper array)
with open(dsl_file, "r") as f:
    content = f.read().strip()
    if not content.startswith("["):
        content = "[" + content + "]"
    queries = json.loads(content)

results = []
total = len(queries)
passed = 0
failed = 0

for i, q in enumerate(queries):
    name = q.get("name", f"query-{i}")
    path = q.get("path", "/_search")
    body = q.get("body", {})
    url = f"http://{host}:9200/{index}{path}"

    print(f"  Running {name} ({i+1}/{total})... ", end="", flush=True)

    try:
        result = subprocess.run(
            ["curl", "-s", "--max-time", "60", "-X", "POST", url,
             "-H", "Content-Type: application/json",
             "-d", json.dumps(body)],
            capture_output=True, text=True, timeout=65
        )
        try:
            response = json.loads(result.stdout)
        except:
            response = {"raw": result.stdout}

        if "error" in response:
            status = "error"
            failed += 1
            print("FAIL")
        else:
            status = "pass"
            passed += 1
            print("PASS")
    except Exception as e:
        response = {"error": str(e)}
        status = "error"
        failed += 1
        print("FAIL")

    results.append({"name": name, "status": status, "response": response})

# Write output
output = {
    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "engine": engine,
    "host": f"{host}:9200",
    "query_type": "dsl",
    "results": results
}

with open(output_file, "w") as f:
    json.dump(output, f, indent=2)

print(f"\n============================================")
print(f"  DSL Correctness Test Complete: {engine}")
print(f"  Total: {total} | Pass: {passed} | Fail: {failed}")
print(f"  Output: {output_file}")
print(f"============================================")

# Upload to S3
if s3_bucket:
    s3_path = f"s3://{s3_bucket}/runs/{run_id}/correctness-results/{engine}/{engine}-correctness-{timestamp}.json"
    ret = os.system(f'aws s3 cp "{output_file}" "{s3_path}"')
    if ret == 0:
        print(f"Uploaded to: {s3_path}")
    else:
        print("Failed to upload to S3.")
PYEOF
