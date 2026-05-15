#!/bin/bash
set -euo pipefail

# =============================================================================
# setup-env.sh — Auto-generates the .env file for CDK deployment
#
# What it does:
#   1. Checks you're logged in to AWS
#   2. Gets your AWS account ID
#   3. Finds the default VPC in your region
#   4. Picks the first public subnet in that VPC
#   5. Finds or creates a security group with SSH (22) and OpenSearch (9200) open
#   6. Finds or creates an EC2 key pair
#   7. Finds or creates an S3 bucket for profiler flamegraphs
#   8. Writes everything to .env
#
# Usage:
#   ./scripts/setup-env.sh                    # uses defaults (us-east-1)
#   ./scripts/setup-env.sh --region us-west-2 # specify region
#   ./scripts/setup-env.sh --key-name my-key  # use existing key pair
# =============================================================================

# --- Default values ---
REGION="us-east-1"
KEY_NAME=""
SG_NAME="opensearch-benchmark"
S3_BUCKET=""
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"

# --- Parse command line arguments ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --region)     REGION="$2"; shift 2 ;;
    --key-name)   KEY_NAME="$2"; shift 2 ;;
    --sg-name)    SG_NAME="$2"; shift 2 ;;
    --s3-bucket)  S3_BUCKET="$2"; shift 2 ;;
    --help)
      echo "Usage: $0 [--region REGION] [--key-name KEY_NAME] [--sg-name SG_NAME] [--s3-bucket BUCKET_NAME]"
      echo ""
      echo "Options:"
      echo "  --region     AWS region (default: us-east-1)"
      echo "  --key-name   Existing EC2 key pair name (default: auto-create 'opensearch-benchmark')"
      echo "  --sg-name    Security group name (default: opensearch-benchmark)"
      echo "  --s3-bucket  S3 bucket for results and flamegraphs (default: opensearch-codeguru-<account-id>)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "============================================"
echo "  OpenSearch CDK — Environment Setup"
echo "============================================"
echo ""

# --- Step 1: Check AWS credentials ---
# We need valid AWS credentials for every API call.
# This fails fast if you haven't logged in yet.
echo "[1/8] Checking AWS credentials..."
if ! aws sts get-caller-identity --region "$REGION" > /dev/null 2>&1; then
  echo "❌ Not logged in to AWS. Please run your AWS login command first."
  echo "   For Amazon employees: ada credentials update --account <account> --role <role>"
  exit 1
fi
echo "  ✅ AWS credentials are valid"

# --- Step 2: Get account ID ---
# Every AWS resource belongs to an account. CDK needs this to know
# which account to deploy into.
echo ""
echo "[2/8] Getting AWS account ID..."
CDK_ACCOUNT=$(aws sts get-caller-identity --region "$REGION" --query 'Account' --output text)
echo "  ✅ Account: $CDK_ACCOUNT"

# Set default S3 bucket name using account ID for global uniqueness
if [ -z "$S3_BUCKET" ]; then
  S3_BUCKET="opensearch-codeguru-${CDK_ACCOUNT}"
fi

# --- Step 3: Find the default VPC ---
# A VPC (Virtual Private Cloud) is your private network in AWS.
# Every account has a "default" VPC created automatically.
# Our EC2 instance will live inside this network.
echo ""
echo "[3/8] Finding default VPC in $REGION..."
VPC_ID=$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' \
  --output text)

if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "❌ No default VPC found in $REGION."
  echo "   Create one with: aws ec2 create-default-vpc --region $REGION"
  exit 1
fi
echo "  ✅ VPC: $VPC_ID"

# --- Step 4: Find a public subnet ---
# A subnet is a slice of the VPC's IP range in a specific availability zone.
# We need a public subnet (one that has a route to the internet) so we can
# SSH into the instance and it can download code from GitHub.
echo ""
echo "[4/8] Finding a public subnet..."
SUBNET_INFO=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[0].[SubnetId,AvailabilityZone]' \
  --output text)

SUBNET_ID=$(echo "$SUBNET_INFO" | awk '{print $1}')
SUBNET_AZ=$(echo "$SUBNET_INFO" | awk '{print $2}')

if [ "$SUBNET_ID" = "None" ] || [ -z "$SUBNET_ID" ]; then
  # Fallback: just pick the first subnet if no public ones found
  echo "  ⚠️  No public subnet found, picking first available subnet..."
  SUBNET_INFO=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[0].[SubnetId,AvailabilityZone]' \
    --output text)
  SUBNET_ID=$(echo "$SUBNET_INFO" | awk '{print $1}')
  SUBNET_AZ=$(echo "$SUBNET_INFO" | awk '{print $2}')
fi

if [ "$SUBNET_ID" = "None" ] || [ -z "$SUBNET_ID" ]; then
  echo "❌ No subnets found in VPC $VPC_ID"
  exit 1
fi
echo "  ✅ Subnet: $SUBNET_ID (AZ: $SUBNET_AZ)"

# --- Step 5: Find or create security group ---
# A security group is a firewall for your EC2 instance.
# It controls which ports are open for incoming/outgoing traffic.
# We need port 22 (SSH) and port 9200 (OpenSearch REST API).
echo ""
echo "[5/8] Setting up security group '$SG_NAME'..."

# Check if the security group already exists
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null)

if [ "$SECURITY_GROUP_ID" = "None" ] || [ -z "$SECURITY_GROUP_ID" ]; then
  # Create a new security group
  echo "  Creating security group..."
  SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "$SG_NAME" \
    --description "Security group for OpenSearch benchmark instances" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' \
    --output text)

  # Open port 22 (SSH) — allows you to connect to the instance
  aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 > /dev/null

  # Allow all traffic within the security group (node-to-node, benchmark-to-opensearch, ALB-to-nodes)
  # This covers ports 9200 (REST) and 9300 (transport) without exposing them via CIDR rules.
  # No explicit 9200/9300 CIDR rules — avoids Palisade flagging open ElasticSearch endpoints.
  aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol -1 \
    --source-group "$SECURITY_GROUP_ID" > /dev/null

  echo "  ✅ Created security group: $SECURITY_GROUP_ID (SSH: 0.0.0.0/0, internal: all within SG)"
else
  echo "  ✅ Found existing security group: $SECURITY_GROUP_ID"
fi

# --- Step 6: Find or create key pair ---
# The key pair lets you SSH into the EC2 instance.
# The private key (.pem file) stays on your machine.
# The public key gets injected into the instance at boot.
echo ""
echo "[6/8] Setting up EC2 key pair..."

if [ -z "$KEY_NAME" ]; then
  KEY_NAME="opensearch-benchmark"
fi

# Check if key pair already exists in AWS
KEY_EXISTS=$(aws ec2 describe-key-pairs \
  --region "$REGION" \
  --key-names "$KEY_NAME" \
  --query 'KeyPairs[0].KeyName' \
  --output text 2>/dev/null || echo "None")

if [ "$KEY_EXISTS" = "None" ]; then
  # Create a new key pair and save the private key
  PEM_FILE="$HOME/$KEY_NAME.pem"
  echo "  Creating key pair '$KEY_NAME'..."
  aws ec2 create-key-pair \
    --region "$REGION" \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' \
    --output text > "$PEM_FILE"
  chmod 400 "$PEM_FILE"
  echo "  ✅ Created key pair: $KEY_NAME"
  echo "  📁 Private key saved to: $PEM_FILE"
  echo "  ⚠️  Keep this file safe! You can't download it again."
else
  echo "  ✅ Found existing key pair: $KEY_NAME"
fi

# --- Step 7: Find or create S3 bucket for profiler flamegraphs ---
# The profiling script on the EC2 instance uploads CPU flamegraphs to S3.
# This bucket needs to exist before the instance tries to upload.
echo ""
echo "[7/8] Setting up S3 bucket '$S3_BUCKET'..."

if aws s3api head-bucket --bucket "$S3_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "  ✅ Found existing bucket: $S3_BUCKET"
else
  echo "  Creating S3 bucket..."
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "$S3_BUCKET" \
      --region "$REGION" > /dev/null
  else
    aws s3api create-bucket \
      --bucket "$S3_BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" > /dev/null
  fi
  echo "  ✅ Created bucket: $S3_BUCKET"
fi

# --- Step 8: Find or create AOS metrics store domain ---
# OSB telemetry (node-stats) requires an OpenSearch metrics store to persist data.
# This domain is created once and reused across deploys (like the S3 bucket).
echo ""
METRICS_DOMAIN_NAME="osb-metrics"
echo "[8/9] Setting up AOS metrics store domain '$METRICS_DOMAIN_NAME'..."

METRICS_ENDPOINT=$(aws opensearch describe-domain \
  --domain-name "$METRICS_DOMAIN_NAME" \
  --region "$REGION" \
  --query 'DomainStatus.Endpoints.vpc' \
  --output text 2>/dev/null || echo "None")

if [ "$METRICS_ENDPOINT" != "None" ] && [ -n "$METRICS_ENDPOINT" ]; then
  echo "  ✅ Found existing metrics store: $METRICS_ENDPOINT"
else
  echo "  Creating AOS domain (this takes 10-15 minutes on first run)..."

  # Ensure service-linked role exists
  aws iam create-service-linked-role \
    --aws-service-name opensearchservice.amazonaws.com \
    --region "$REGION" 2>/dev/null || true

  aws opensearch create-domain \
    --domain-name "$METRICS_DOMAIN_NAME" \
    --engine-version OpenSearch_2.17 \
    --cluster-config InstanceType=t3.small.search,InstanceCount=1,DedicatedMasterEnabled=false,ZoneAwarenessEnabled=false \
    --ebs-options EBSEnabled=true,VolumeType=gp3,VolumeSize=20 \
    --vpc-options SubnetIds="$SUBNET_ID",SecurityGroupIds="$SECURITY_GROUP_ID" \
    --access-policies "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"*\"},\"Action\":\"es:*\",\"Resource\":\"arn:aws:es:${REGION}:${CDK_ACCOUNT}:domain/${METRICS_DOMAIN_NAME}/*\"}]}" \
    --domain-endpoint-options EnforceHTTPS=false \
    --region "$REGION" > /dev/null

  echo "  ⏳ Waiting for domain to become active..."
  while true; do
    PROCESSING=$(aws opensearch describe-domain \
      --domain-name "$METRICS_DOMAIN_NAME" \
      --region "$REGION" \
      --query 'DomainStatus.Processing' \
      --output text 2>/dev/null)
    if [ "$PROCESSING" = "False" ]; then
      break
    fi
    echo "    Still creating... (checking again in 30s)"
    sleep 30
  done

  METRICS_ENDPOINT=$(aws opensearch describe-domain \
    --domain-name "$METRICS_DOMAIN_NAME" \
    --region "$REGION" \
    --query 'DomainStatus.Endpoints.vpc' \
    --output text)

  echo "  ✅ Created metrics store: $METRICS_ENDPOINT"
fi

# --- Step 9: Write .env file ---
# This file is read by CDK (via dotenv) when you run 'npx cdk deploy'.
# It tells CDK which AWS resources to use for the deployment.
echo ""
echo "[9/9] Writing .env file..."

cat > "$ENV_FILE" << EOF
# Auto-generated by setup-env.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Region: $REGION

# AWS Account and Region
CDK_ACCOUNT=$CDK_ACCOUNT
CDK_REGION=$REGION

# Networking (auto-discovered from default VPC)
VPC_ID=$VPC_ID
SUBNET_ID=$SUBNET_ID
SUBNET_AZ=$SUBNET_AZ
SECURITY_GROUP_ID=$SECURITY_GROUP_ID

# SSH Key Pair
KEY_PAIR_NAME=$KEY_NAME
PEM_PATH=\$HOME/$KEY_NAME.pem

# S3 bucket for profiler, benchmark results, and correctness results
S3_BUCKET=$S3_BUCKET

# Parquet OpenSearch build config (defaults — override as needed)
# PARQUET_REPO=https://github.com/opensearch-project/OpenSearch.git
# PARQUET_BRANCH=main

# Instance config (defaults — override as needed)
# INSTANCE_TYPE=r7g.2xlarge
# EBS_SIZE_GB=100
# EBS_IOPS=3000
# EBS_THROUGHPUT=125
# JVM_HEAP=8g

# Stack suffix for multi-user deployments (e.g., your alias)
# STACK_SUFFIX=

# Benchmark config (defaults — override as needed)
# BENCHMARK_ENABLED=true
# BENCHMARK_INSTANCE_TYPE=m7g.medium
# BENCHMARK_EBS_SIZE_GB=500
# WORKLOAD_REPO=https://github.com/HarishNarasimhanK/opensearch-benchmark-workloads.git
# WORKLOAD_BRANCH=main

# Lucene OpenSearch config (defaults — override as needed)
# LUCENE_ENABLED=true
# LUCENE_REPO=https://github.com/opensearch-project/OpenSearch.git
# LUCENE_BRANCH=main

# OSB Metrics Store (AOS domain for telemetry data — persists across deploys)
METRICS_STORE_HOST=$METRICS_ENDPOINT
METRICS_STORE_PORT=443
METRICS_STORE_SECURE=True
EOF

echo "  ✅ Written to: $ENV_FILE"

# --- Done ---
echo ""
echo "============================================"
echo "  ✅ Setup complete!"
echo "============================================"
echo ""
echo "  .env file: $ENV_FILE"
echo "  Region:    $REGION"
echo "  Account:   $CDK_ACCOUNT"
echo "  VPC:       $VPC_ID"
echo "  Subnet:    $SUBNET_ID ($SUBNET_AZ)"
echo "  SG:        $SECURITY_GROUP_ID"
echo "  Key Pair:  $KEY_NAME"
echo "  S3 Bucket: $S3_BUCKET"
echo "  Metrics:   $METRICS_ENDPOINT"
echo ""
echo "Next steps:"
echo "  1. Review the .env file: cat $ENV_FILE"
echo "  2. Deploy: npx cdk deploy"
echo ""
