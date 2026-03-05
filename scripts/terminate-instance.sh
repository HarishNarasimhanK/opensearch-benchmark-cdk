#!/bin/bash
set -euo pipefail

INSTANCE_ID="${1:?Usage: $0 <instance-id>}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

echo "Terminating instance $INSTANCE_ID in $REGION..."
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
echo "Waiting for termination..."
aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"
echo "Instance $INSTANCE_ID terminated."
