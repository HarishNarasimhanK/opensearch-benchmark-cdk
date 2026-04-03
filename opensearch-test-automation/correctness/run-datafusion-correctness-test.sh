#!/bin/bash
set -euo pipefail

# =============================================================================
# run-correctness-test.sh — Runs all 43 PPL queries and captures raw responses
#
# Usage:
#   bash correctness/run-correctness-test.sh <host> <engine-name>
#   bash correctness/run-correctness-test.sh 172.31.85.56 datafusion
#   bash correctness/run-correctness-test.sh 172.31.81.86 lucene
#
# Reads S3_BUCKET from ~/.opensearch-env
# =============================================================================

source "$HOME/.opensearch-env" 2>/dev/null || true

OS_HOST="${1:?Usage: $0 <host> <engine-name>}"
ENGINE="${2:?Usage: $0 <host> <engine-name>}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="$HOME/correctness-results/${ENGINE}"
OUTPUT_FILE="${RESULTS_DIR}/${ENGINE}-correctness-${TIMESTAMP}.json"
mkdir -p "$RESULTS_DIR"

echo "============================================"
echo "  Correctness Test: ${ENGINE}"
echo "  Target: ${OS_HOST}:9200"
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

INDEX="clickbench"

# All 43 PPL queries from the clickbench workload
declare -a QUERY_NAMES=(
  "q01-count-all"
  "q02-count-adv-engine"
  "q03-sum-count-avg"
  "q04-avg-userid"
  "q05-distinct-userid"
  "q06-distinct-searchphrase"
  "q07-min-max-eventdate"
  "q08-group-by-adv-engine"
  "q09-region-users"
  "q10-region-stats"
  "q11-mobile-phone-model"
  "q12-mobile-phone-stats"
  "q13-search-phrase-count"
  "q14-search-phrase-users"
  "q15-search-engine-phrase"
  "q16-user-activity"
  "q17-user-search-activity"
  "q18-user-search-limit"
  "q19-user-minute-search"
  # "q20-specific-user"              # SKIPPED: crashes datafusion OpenSearch (projection.rs off-by-one panic)
  "q21-google-urls"
  "q22-google-search-phrases"
  "q23-google-title-search"
  # "q24-google-urls-sorted"         # SKIPPED: crashes datafusion OpenSearch (projection.rs off-by-one panic)
  # "q25-search-phrases-by-time"     # SKIPPED: crashes datafusion OpenSearch (projection.rs off-by-one panic)
  # "q26-search-phrases-sorted"      # SKIPPED: crashes datafusion OpenSearch (projection.rs off-by-one panic)
  # "q27-search-phrases-multi-sort"  # SKIPPED: crashes datafusion OpenSearch (projection.rs off-by-one panic)
  "q28-counter-url-length"
  "q30-resolution-width-sums"
  "q31-search-engine-client-stats"
  "q32-watch-client-stats"
  "q33-watch-client-all"
  "q34-url-popularity"
  "q35-url-with-constant"
  "q36-client-ip-variations"
  "q37-counter-62-urls"
  "q38-counter-62-titles"
  "q39-counter-62-links"
  "q40-traffic-source-analysis"
  "q41-url-hash-date"
  "q42-window-client-dimensions"
  "q43-hourly-pageviews"
)

declare -A QUERIES
QUERIES["q01-count-all"]="source = ${INDEX} | stats count()"
QUERIES["q02-count-adv-engine"]="source = ${INDEX} | where AdvEngineID!=0 | stats count()"
QUERIES["q03-sum-count-avg"]="source = ${INDEX} | stats sum(AdvEngineID), count(), avg(ResolutionWidth)"
QUERIES["q04-avg-userid"]="source = ${INDEX} | stats avg(UserID)"
QUERIES["q05-distinct-userid"]="source = ${INDEX} | stats dc(UserID)"
QUERIES["q06-distinct-searchphrase"]="source = ${INDEX} | stats dc(SearchPhrase)"
QUERIES["q07-min-max-eventdate"]="source = ${INDEX} | stats min(EventDate), max(EventDate)"
QUERIES["q08-group-by-adv-engine"]="source = ${INDEX} | where AdvEngineID!=0 | stats count() by AdvEngineID | sort - \`count()\`"
QUERIES["q09-region-users"]="source = ${INDEX} | stats dc(UserID) as u by RegionID | sort -u | head 10"
QUERIES["q10-region-stats"]="source = ${INDEX} | stats sum(AdvEngineID), count() as c, avg(ResolutionWidth), dc(UserID) by RegionID | sort - c | head 10"
QUERIES["q11-mobile-phone-model"]="source = ${INDEX} | where MobilePhoneModel != '' | stats dc(UserID) as u by MobilePhoneModel | sort - u | head 10"
QUERIES["q12-mobile-phone-stats"]="source = ${INDEX} | where MobilePhoneModel != '' | stats dc(UserID) as u by MobilePhone, MobilePhoneModel | sort - u | head 10"
QUERIES["q13-search-phrase-count"]="source = ${INDEX} | where SearchPhrase != '' | stats count() as c by SearchPhrase | sort - c | head 10"
QUERIES["q14-search-phrase-users"]="source = ${INDEX} | where SearchPhrase != '' | stats dc(UserID) as u by SearchPhrase | sort - u | head 10"
QUERIES["q15-search-engine-phrase"]="source = ${INDEX} | where SearchPhrase != '' | stats count() as c by SearchEngineID, SearchPhrase | sort - c | head 10"
QUERIES["q16-user-activity"]="source = ${INDEX} | stats count() by UserID | sort - \`count()\` | head 10"
QUERIES["q17-user-search-activity"]="source = ${INDEX} | stats count() by UserID, SearchPhrase | sort - \`count()\` | head 10"
QUERIES["q18-user-search-limit"]="source = ${INDEX} | stats count() by UserID, SearchPhrase | head 10"
QUERIES["q19-user-minute-search"]="source = ${INDEX} | eval m = extract(minute from EventTime) | stats count() by UserID, m, SearchPhrase | sort - \`count()\` | head 10"
QUERIES["q20-specific-user"]="source = ${INDEX} | where UserID = 435090932899640449 | fields UserID"
QUERIES["q21-google-urls"]="source = ${INDEX} | where like(URL, '%google%') | stats count()"
QUERIES["q22-google-search-phrases"]="source = ${INDEX} | where like(URL, '%google%') and SearchPhrase != '' | stats count() as c by SearchPhrase | sort - c | head 10"
QUERIES["q23-google-title-search"]="source = ${INDEX} | where like(Title, '%Google%') and not like(URL, '%.google.%') and SearchPhrase != '' | stats count() as c, dc(UserID) by SearchPhrase | sort - c | head 10"
QUERIES["q24-google-urls-sorted"]="source = ${INDEX} | where like(URL, '%google%') | sort EventTime | head 10"
QUERIES["q25-search-phrases-by-time"]="source = ${INDEX} | where SearchPhrase != '' | sort EventTime | fields SearchPhrase | head 10"
QUERIES["q26-search-phrases-sorted"]="source = ${INDEX} | where SearchPhrase != '' | fields SearchPhrase | sort SearchPhrase | head 10"
QUERIES["q27-search-phrases-multi-sort"]="source = ${INDEX} | where SearchPhrase != '' | sort EventTime, SearchPhrase | fields SearchPhrase | head 10"
QUERIES["q28-counter-url-length"]="source = ${INDEX} | where URL != '' | stats avg(length(URL)) as l, count() as c by CounterID | where c > 100000 | sort - l | head 25"
QUERIES["q30-resolution-width-sums"]="source = ${INDEX} | stats sum(ResolutionWidth), sum(ResolutionWidth+1), sum(ResolutionWidth+2), sum(ResolutionWidth+3), sum(ResolutionWidth+4), sum(ResolutionWidth+5), sum(ResolutionWidth+6), sum(ResolutionWidth+7), sum(ResolutionWidth+8), sum(ResolutionWidth+9)"
QUERIES["q31-search-engine-client-stats"]="source = ${INDEX} | where SearchPhrase != '' | stats count() as c, sum(IsRefresh), avg(ResolutionWidth) by SearchEngineID, ClientIP | sort - c | head 10"
QUERIES["q32-watch-client-stats"]="source = ${INDEX} | where SearchPhrase != '' | stats count() as c, sum(IsRefresh), avg(ResolutionWidth) by WatchID, ClientIP | sort - c | head 10"
QUERIES["q33-watch-client-all"]="source = ${INDEX} | stats count() as c, sum(IsRefresh), avg(ResolutionWidth) by WatchID, ClientIP | sort - c | head 10"
QUERIES["q34-url-popularity"]="source = ${INDEX} | stats count() as c by URL | sort - c | head 10"
QUERIES["q35-url-with-constant"]="source = ${INDEX} | eval const = 1 | stats count() as c by const, URL | sort - c | head 10"
QUERIES["q36-client-ip-variations"]="source = ${INDEX} | eval \`ClientIP - 1\` = ClientIP - 1, \`ClientIP - 2\` = ClientIP - 2, \`ClientIP - 3\` = ClientIP - 3 | stats count() as c by ClientIP, \`ClientIP - 1\`, \`ClientIP - 2\`, \`ClientIP - 3\` | sort - c | head 10"
QUERIES["q37-counter-62-urls"]="source = ${INDEX} | where CounterID = 62 and EventDate >= '2013-07-01 00:00:00' and EventDate <= '2013-07-31 00:00:00' and DontCountHits = 0 and IsRefresh = 0 and URL != '' | stats count() as PageViews by URL | sort - PageViews | head 10"
QUERIES["q38-counter-62-titles"]="source = ${INDEX} | where CounterID = 62 and EventDate >= '2013-07-01 00:00:00' and EventDate <= '2013-07-31 00:00:00' and DontCountHits = 0 and IsRefresh = 0 and Title != '' | stats count() as PageViews by Title | sort - PageViews | head 10"
QUERIES["q39-counter-62-links"]="source = ${INDEX} | where CounterID = 62 and EventDate >= '2013-07-01 00:00:00' and EventDate <= '2013-07-31 00:00:00' and IsRefresh = 0 and IsLink != 0 and IsDownload = 0 | stats count() as PageViews by URL | sort - PageViews | head 10 from 1000"
QUERIES["q40-traffic-source-analysis"]="source = ${INDEX} | where CounterID = 62 and EventDate >= '2013-07-01 00:00:00' and EventDate <= '2013-07-31 00:00:00' and IsRefresh = 0 | eval Src=case(SearchEngineID = 0 and AdvEngineID = 0, Referer else ''), Dst=URL | stats count() as PageViews by TraficSourceID, SearchEngineID, AdvEngineID, Src, Dst | sort - PageViews | head 10 from 1000"
QUERIES["q41-url-hash-date"]="source = ${INDEX} | where CounterID = 62 and EventDate >= '2013-07-01 00:00:00' and EventDate <= '2013-07-31 00:00:00' and IsRefresh = 0 and TraficSourceID in (-1, 6) and RefererHash = 3594120000172545465 | stats count() as PageViews by URLHash, EventDate | sort - PageViews | head 10 from 100"
QUERIES["q42-window-client-dimensions"]="source = ${INDEX} | where CounterID = 62 and EventDate >= '2013-07-01 00:00:00' and EventDate <= '2013-07-31 00:00:00' and IsRefresh = 0 and DontCountHits = 0 and URLHash = 2868770270353813622 | stats count() as PageViews by WindowClientWidth, WindowClientHeight | sort - PageViews | head 10 from 10000"
QUERIES["q43-hourly-pageviews"]="source = ${INDEX} | where CounterID = 62 and EventDate >= '2013-07-01 00:00:00' and EventDate <= '2013-07-15 00:00:00' and IsRefresh = 0 and DontCountHits = 0 | eval M = date_format(EventTime, '%Y-%m-%d %H:00:00') | stats count() as PageViews by M | sort M | head 10 from 1000"

# --- Build JSON output ---
echo "{" > "$OUTPUT_FILE"
echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," >> "$OUTPUT_FILE"
echo "  \"engine\": \"${ENGINE}\"," >> "$OUTPUT_FILE"
echo "  \"host\": \"${OS_HOST}:9200\"," >> "$OUTPUT_FILE"
echo "  \"results\": [" >> "$OUTPUT_FILE"

TOTAL=${#QUERY_NAMES[@]}
COUNT=0
PASS=0
FAIL=0

for name in "${QUERY_NAMES[@]}"; do
  COUNT=$((COUNT + 1))
  query="${QUERIES[$name]}"
  echo -n "  Running ${name} (${COUNT}/${TOTAL})... "

  response=$(curl -s --max-time 60 -X POST "http://${OS_HOST}:9200/_plugins/_ppl" \
    -H 'Content-Type: application/json' \
    -d "{\"query\": \"${query}\"}" 2>&1) || response="{\"error\": \"curl failed or timed out\"}"

  if echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'error' not in d else 1)" 2>/dev/null; then
    status="pass"
    PASS=$((PASS + 1))
    echo "PASS"
  else
    status="error"
    FAIL=$((FAIL + 1))
    echo "FAIL"
  fi

  comma=""
  if [ $COUNT -lt $TOTAL ]; then comma=","; fi

  python3 -c "
import json, sys
name, query, status, response, comma = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
try: resp = json.loads(response)
except: resp = {'raw': response}
print('    ' + json.dumps({'name': name, 'query': query, 'status': status, 'response': resp}) + comma)
" "$name" "$query" "$status" "$response" "$comma" >> "$OUTPUT_FILE"
done

echo "  ]" >> "$OUTPUT_FILE"
echo "}" >> "$OUTPUT_FILE"

echo ""
echo "============================================"
echo "  Correctness Test Complete: ${ENGINE}"
echo "  Total: ${TOTAL} | Pass: ${PASS} | Fail: ${FAIL}"
echo "  Output: ${OUTPUT_FILE}"
echo "============================================"

# --- Upload to S3 ---
if [ -n "${S3_BUCKET:-}" ]; then
  if aws s3 cp "$OUTPUT_FILE" "s3://${S3_BUCKET}/correctness-results/${ENGINE}/${ENGINE}-correctness-${TIMESTAMP}.json"; then
    echo "Uploaded to: s3://${S3_BUCKET}/correctness-results/${ENGINE}/"
  else
    echo "Failed to upload to S3."
  fi
fi
