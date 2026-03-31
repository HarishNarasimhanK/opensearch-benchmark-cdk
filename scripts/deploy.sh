#!/bin/bash
set -euo pipefail

source .env

STACK_NAME="OpenSearchCodeGuruStack"
if [ -n "${STACK_SUFFIX:-}" ]; then
  STACK_NAME="OpenSearchCodeGuruStack-${STACK_SUFFIX}"
fi

echo "Deploying ${STACK_NAME}..."
npx cdk deploy "${STACK_NAME}" --require-approval never --outputs-file cdk-outputs.json 2>&1

echo ""
echo "=== Deployment Complete ==="
echo "Outputs written to cdk-outputs.json"
echo ""

# --- DataFusion OpenSearch Instance ---
INSTANCE_ID=$(jq -r ".\"${STACK_NAME}\".InstanceId // empty" cdk-outputs.json)
PRIVATE_IP=$(jq -r ".\"${STACK_NAME}\".PrivateIp // empty" cdk-outputs.json)
SSH_CMD=$(jq -r ".\"${STACK_NAME}\".SSHCommand // empty" cdk-outputs.json)

if [ -n "$INSTANCE_ID" ]; then
  echo "--- DataFusion OpenSearch ---"
  echo "  Instance ID:  $INSTANCE_ID"
  echo "  Private IP:   $PRIVATE_IP"
  echo "  SSH:          ssh -i \$HOME/${KEY_PAIR_NAME}.pem ec2-user@<public-dns>"
  echo "  Build log:    tail -f /var/log/user-data.log"
  echo "  Runtime log:  tail -f ~/datafusion-opensearch-run.log"
  echo ""
fi

# --- Lucene OpenSearch Instance ---
LUCENE_ID=$(jq -r ".\"${STACK_NAME}\".LuceneInstanceId // empty" cdk-outputs.json)
LUCENE_IP=$(jq -r ".\"${STACK_NAME}\".LucenePrivateIp // empty" cdk-outputs.json)

if [ -n "$LUCENE_ID" ]; then
  echo "--- Lucene OpenSearch ---"
  echo "  Instance ID:  $LUCENE_ID"
  echo "  Private IP:   $LUCENE_IP"
  echo "  SSH:          $(jq -r ".\"${STACK_NAME}\".LuceneSSHCommand // empty" cdk-outputs.json)"
  echo "  Build log:    tail -f /var/log/user-data.log"
  echo "  Runtime log:  tail -f ~/lucene-opensearch-run.log"
  echo ""
fi

# --- Benchmark Instance ---
BENCHMARK_ID=$(jq -r ".\"${STACK_NAME}\".BenchmarkInstanceId // empty" cdk-outputs.json)

if [ -n "$BENCHMARK_ID" ]; then
  echo "--- Benchmark ---"
  echo "  Instance ID:  $BENCHMARK_ID"
  echo "  SSH:          $(jq -r ".\"${STACK_NAME}\".BenchmarkSSHCommand // empty" cdk-outputs.json)"
  echo "  Run log:      tail -f ~/benchmark-run.log"
  echo ""
fi
