# FAQ — OpenSearch Benchmark CDK

## "Stack cannot be deleted while in status UPDATE_IN_PROGRESS"

```
❌ Stack [OpenSearchCodeGuruStack] cannot be deleted while in status UPDATE_IN_PROGRESS
```

**Why:** You tried to destroy the stack while a deploy/update is still running. CloudFormation won't let you delete a stack mid-operation.

**Fix:** Wait for the update to finish, then destroy.

```bash
# Check current status:
aws cloudformation describe-stacks --stack-name OpenSearchCodeGuruStack \
  --query 'Stacks[0].StackStatus' --output text

# Wait for it to complete (blocks until done):
aws cloudformation wait stack-update-complete --stack-name OpenSearchCodeGuruStack

# Now destroy:
npx cdk destroy --force
```

If the update is stuck or failed, you can cancel it first:

```bash
aws cloudformation cancel-update-stack --stack-name OpenSearchCodeGuruStack

# Wait for rollback to finish:
aws cloudformation wait stack-rollback-complete --stack-name OpenSearchCodeGuruStack

# Then destroy:
npx cdk destroy --force
```

---

## "Stack is in DELETE_FAILED state"

**Why:** Some resources couldn't be deleted (usually non-empty S3 buckets or resources with termination protection).

**Fix:**

```bash
# See which resources failed:
aws cloudformation describe-stack-events --stack-name OpenSearchCodeGuruStack \
  --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
  --output table

# Retry delete, skipping the problematic resources:
aws cloudformation delete-stack --stack-name OpenSearchCodeGuruStack \
  --retain-resources LogicalId1 LogicalId2
```

---

## "I deployed with a prefix but want to destroy it"

If you deployed with `-c stackSuffix=harish`, the stack name is `OpenSearchCodeGuruStack-harish`:

```bash
npx cdk destroy OpenSearchCodeGuruStack-harish --force
```

---

## "How do I see what's running?"

```bash
# List all your benchmark stacks:
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query 'StackSummaries[?starts_with(StackName,`OpenSearchCodeGuruStack`)].[StackName,StackStatus,CreationTime]' \
  --output table
```

---

## "Builder instance is still running / costing money"

The builder runs `shutdown -h now` after uploading builds. This stops the instance but doesn't terminate it — EBS storage still costs money.

**To terminate manually:**

```bash
# Find it:
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*Builder*" "Name=instance-state-name,Values=stopped" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# Terminate:
aws ec2 terminate-instances --instance-ids i-xxxxxxxxx
```

Or just destroy the whole stack — it terminates everything.

---

## "Deploy says 'No .env file found' and runs setup-env.sh"

This is normal on first run. `setup-env.sh` auto-discovers your VPC, creates a security group, key pair, and S3 bucket. It writes the `.env` file and subsequent deploys reuse it.

If you want to re-run setup (e.g., different region):

```bash
rm .env
./scripts/setup-env.sh --region us-west-2
```

---

## "CloudWatch logs are empty except user-data.log"

Fixed in latest version. The CloudWatch agent needs log files to exist before it starts tailing them. The user-data scripts now pre-create all log files before starting the agent.

If you're on an older deploy, SSH in and restart the agent:

```bash
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
```

---

## "How long does a full benchmark run take?"

Typical timeline (single-node, 100 iterations, 0.1% ingest):

| Phase | Duration |
|---|---|
| Builder: Parquet build (Rust + sandbox) | ~25 min |
| Builder: Lucene build | ~15 min |
| Parquet/Lucene instances: download + start | ~5 min after build |
| Benchmark: ingest + query (per engine) | ~20-40 min |
| Total end-to-end | ~90-120 min |

---

## "Can I run multiple benchmarks in parallel?"

Yes. Use different prefixes:

```bash
# Stack 1: testing main branch
npx cdk deploy -c runIdPrefix=main -c stackSuffix=main

# Stack 2: testing my feature branch
npx cdk deploy -c runIdPrefix=feature -c stackSuffix=feature -c parquetBranch=my-feature
```

Each gets its own EC2 instances, S3 paths, and CloudWatch dashboards.
