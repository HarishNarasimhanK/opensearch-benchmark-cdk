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

# Extract values
INSTANCE_ID=$(jq -r ".\"${STACK_NAME}\".InstanceId" cdk-outputs.json)
PRIVATE_IP=$(jq -r ".\"${STACK_NAME}\".PrivateIp" cdk-outputs.json)

# Fetch public DNS from AWS
PUBLIC_DNS=$(aws ec2 describe-instances \
  --region "${CDK_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].PublicDnsName' \
  --output text 2>/dev/null || echo "N/A")

# Append public DNS to outputs file
jq --arg dns "$PUBLIC_DNS" ".\"${STACK_NAME}\".PublicDns = \$dns" cdk-outputs.json > cdk-outputs.tmp && mv cdk-outputs.tmp cdk-outputs.json

echo "Instance ID:  $INSTANCE_ID"
echo "Private IP:   $PRIVATE_IP"
echo "Public DNS:   $PUBLIC_DNS"
echo ""
echo "SSH command:"
echo "  ssh -i ${PEM_PATH} ec2-user@${PUBLIC_DNS}"
echo ""
echo "Tail build log:"
echo "  ssh -i ${PEM_PATH} ec2-user@${PUBLIC_DNS} 'sudo tail -f /var/log/user-data.log'"
