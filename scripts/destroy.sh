#!/bin/bash
set -euo pipefail

source .env

STACK_NAME="OpenSearchCodeGuruStack"
if [ -n "${STACK_SUFFIX:-}" ]; then
  STACK_NAME="OpenSearchCodeGuruStack-${STACK_SUFFIX}"
fi

echo "Destroying ${STACK_NAME}..."
npx cdk destroy "${STACK_NAME}" --force 2>&1
echo "Stack ${STACK_NAME} destroyed."
