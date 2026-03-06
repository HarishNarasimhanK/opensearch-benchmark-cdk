# OpenSearch Profiler Stack

Provisions an EC2 instance that builds OpenSearch from source and profiles it with [async-profiler](https://github.com/async-profiler/async-profiler). Flamegraphs are uploaded to S3 on a cron schedule.

## Prerequisites

- Node.js 18+, npm
- AWS CDK v2 (`npm install -g aws-cdk`)
- An AWS account with a VPC, subnet, security group, and EC2 key pair
- An S3 bucket for flamegraph uploads
- An IAM instance profile with S3 write access (default: `CloudWatchAgentRole`)

## Quick Start

1. Clone and install:
   ```bash
   git clone <this-repo> && cd <this-repo>
   npm install
   ```

2. Copy and edit `.env`:
   ```bash
   cp .env.example .env   # or edit .env directly
   ```

3. Fill in required values:
   | Variable | Description |
   |---|---|
   | `CDK_ACCOUNT` | AWS account ID |
   | `CDK_REGION` | AWS region |
   | `VPC_ID` | VPC to launch in |
   | `SUBNET_ID` | Subnet (must have public IP assignment) |
   | `SUBNET_AZ` | Subnet availability zone |
   | `SECURITY_GROUP_ID` | SG allowing SSH (port 22) and OpenSearch (port 9200) |
   | `KEY_PAIR_NAME` | EC2 key pair name |
   | `PEM_PATH` | Local path to the `.pem` file |
   | `OPENSEARCH_REPO` | Git URL for OpenSearch fork |
   | `OPENSEARCH_BRANCH` | Branch to build |
   | `S3_PROFILE_BUCKET` | S3 bucket for flamegraph uploads |

4. Deploy:
   ```bash
   bash scripts/deploy.sh
   ```

5. SSH in and tail the build:
   ```bash
   ssh -i <PEM_PATH> ec2-user@<public-dns> 'sudo tail -f /var/log/user-data.log'
   ```

## Optional Config

| Variable | Default | Description |
|---|---|---|
| `STACK_SUFFIX` | _(empty)_ | Deploy multiple stacks side-by-side (e.g. `v2`) |
| `INSTANCE_TYPE` | `r7g.2xlarge` | EC2 instance type (ARM by default) |
| `EBS_SIZE_GB` | `100` | Root volume size |
| `EBS_IOPS` | `3000` | gp3 IOPS |
| `EBS_THROUGHPUT` | `125` | gp3 throughput (MB/s) |
| `SQL_PLUGIN_REPO` | _(disabled)_ | SQL plugin fork URL (build skipped by default) |
| `SQL_PLUGIN_BRANCH` | `substrait-plan` | SQL plugin branch |

## What It Does

1. Launches an ARM EC2 instance (Amazon Linux 2023)
2. Clones and builds OpenSearch from your configured repo/branch
3. Installs async-profiler (ARM build)
4. Starts OpenSearch
5. Runs a cron job every 5 minutes that captures a 60s CPU flamegraph and uploads it to S3

## Commands

```bash
bash scripts/deploy.sh          # Deploy stack
bash scripts/destroy.sh         # Tear down stack
npx cdk synth                   # Preview CloudFormation template
npx cdk destroy <StackName>     # Destroy specific stack
```

## On the EC2 Instance

```bash
./opensearch/bin/opensearch                    # Start OpenSearch manually
./profile-opensearch.sh                        # Run a one-off CPU profile
ls ~/profiles/                                 # View local flamegraphs
aws s3 ls s3://<bucket>/<hostname>/            # View uploaded flamegraphs
```
