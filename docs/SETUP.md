# Infrastructure Setup Guide

Step-by-step guide to create the AWS resources needed before deploying the stack.

All commands assume `us-east-1`. Replace `--region` as needed.

---

## 1. VPC & Subnet

The simplest option is to use the default VPC (every AWS account has one):

```bash
# Get default VPC ID
aws ec2 describe-vpcs --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region us-east-1
```

Pick a subnet with public IP auto-assignment:

```bash
# List subnets in the default VPC
aws ec2 describe-subnets --filters Name=vpc-id,Values=<VPC_ID> \
  --query 'Subnets[*].{SubnetId:SubnetId,AZ:AvailabilityZone,Public:MapPublicIpOnLaunch}' \
  --output table --region us-east-1
```

Choose one where `Public = True`. Set in `.env`:

```
VPC_ID=vpc-xxxxxxxxx
SUBNET_ID=subnet-xxxxxxxxx
SUBNET_AZ=us-east-1c
```

> If no subnet has `MapPublicIpOnLaunch = true`, enable it:
> ```bash
> aws ec2 modify-subnet-attribute --subnet-id subnet-xxx --map-public-ip-on-launch --region us-east-1
> ```

---

## 2. Security Group

Create a security group that allows SSH and OpenSearch access:

```bash
# Create the SG
aws ec2 create-security-group \
  --group-name opensearch-benchmark \
  --description "SSH + OpenSearch access for benchmark instances" \
  --vpc-id <VPC_ID> \
  --region us-east-1
```

Add inbound rules:

```bash
SG_ID=<security-group-id-from-above>

# SSH from your IP
MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID --protocol tcp --port 22 \
  --cidr "$MY_IP/32" --region us-east-1

# OpenSearch (9200) from your IP
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID --protocol tcp --port 9200 \
  --cidr "$MY_IP/32" --region us-east-1
```

Set in `.env`:

```
SECURITY_GROUP_ID=sg-xxxxxxxxx
```

---

## 3. EC2 Key Pair

Create a key pair for SSH access:

```bash
aws ec2 create-key-pair \
  --key-name opensearch-benchmark \
  --key-type rsa \
  --query 'KeyMaterial' --output text \
  --region us-east-1 > opensearch-benchmark.pem

chmod 400 opensearch-benchmark.pem
```

Set in `.env`:

```
KEY_PAIR_NAME=opensearch-benchmark
PEM_PATH=/path/to/opensearch-benchmark.pem
```

---

## 4. S3 Bucket (for flamegraphs)

Create a bucket to store async-profiler output:

```bash
aws s3 mb s3://my-profiler-bucket --region us-east-1
```

Set in `.env`:

```
S3_PROFILE_BUCKET=my-profiler-bucket
```

---

## 5. IAM Instance Profile

The EC2 instance needs an IAM role with S3 write access for uploading flamegraphs. You can use the existing `CloudWatchAgentRole` or create your own.

### Option A: Use the existing `CloudWatchAgentRole`

The stack currently uses `CloudWatchAgentRole` (hardcoded in `lib/opensearch-codeguru-stack.ts`).

This role has the following attached policies:

| Policy | Type | Purpose |
|---|---|---|
| `AmazonS3FullAccess` | AWS managed | S3 read/write for flamegraph uploads |
| `CloudWatchAgentAdminPolicy` | AWS managed | CloudWatch metrics/logs |
| `AdministratorAccess` | AWS managed | Broad access (consider scoping down) |
| `AmazonCodeGuruProfilerFullAccess` | AWS managed | Legacy — no longer needed |
| `CodeGuruEc2Policy` | Inline | Legacy — no longer needed |

Trust policy (allows EC2 to assume the role):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
```

To verify it exists:

```bash
aws iam get-instance-profile --instance-profile-name CloudWatchAgentRole \
  --query 'InstanceProfile.Arn' --output text
```

> **Note:** The `AdministratorAccess`, `AmazonCodeGuruProfilerFullAccess`, and `CodeGuruEc2Policy` policies are broader than needed. For a minimal setup, only `AmazonS3FullAccess` (or a scoped-down S3 policy) is required.

### Option B: Create a minimal role from scratch

```bash
# Create the role
aws iam create-role --role-name OpenSearchBenchmarkRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

# Attach scoped S3 policy for flamegraph uploads
aws iam put-role-policy --role-name OpenSearchBenchmarkRole \
  --policy-name S3ProfileUpload \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::my-profiler-bucket/*"
    }]
  }'

# Attach SSM for remote access (optional but recommended)
aws iam attach-role-policy --role-name OpenSearchBenchmarkRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Create instance profile and attach role
aws iam create-instance-profile --instance-profile-name OpenSearchBenchmarkRole
aws iam add-role-to-instance-profile \
  --instance-profile-name OpenSearchBenchmarkRole \
  --role-name OpenSearchBenchmarkRole
```

Then update the instance profile ARN in `lib/opensearch-codeguru-stack.ts`:

```typescript
const instanceProfile = iam.InstanceProfile.fromInstanceProfileAttributes(this, "ExistingInstanceProfile", {
  instanceProfileArn: "arn:aws:iam::<ACCOUNT_ID>:instance-profile/OpenSearchBenchmarkRole",
  role: iam.Role.fromRoleName(this, "OpenSearchInstanceRole", "OpenSearchBenchmarkRole"),
});
```

> **TODO:** The instance profile ARN is currently hardcoded in `lib/opensearch-codeguru-stack.ts`. Consider making it configurable via `.env` if your team uses different roles.

---

## 6. Final `.env` Checklist

```env
CDK_ACCOUNT=123456789012
CDK_REGION=us-east-1
VPC_ID=vpc-xxxxxxxxx
SUBNET_ID=subnet-xxxxxxxxx
SUBNET_AZ=us-east-1c
SECURITY_GROUP_ID=sg-xxxxxxxxx
KEY_PAIR_NAME=opensearch-benchmark
PEM_PATH=/path/to/opensearch-benchmark.pem
OPENSEARCH_REPO=https://github.com/opensearch-project/OpenSearch.git
OPENSEARCH_BRANCH=main
S3_PROFILE_BUCKET=my-profiler-bucket
INSTANCE_TYPE=r7g.2xlarge
EBS_SIZE_GB=100
EBS_IOPS=3000
EBS_THROUGHPUT=125
```

Then deploy:

```bash
npm install
bash scripts/deploy.sh
```
