# OpenSearch Performance & Correctness Test Infrastructure

One-command CDK stack that provisions EC2 instances to benchmark and compare the DataFusion engine against vanilla Lucene OpenSearch. Supports both single-node and multi-node cluster modes.

- **Builder Instance** — builds both DataFusion and Lucene OpenSearch from source, uploads pre-built tar.gz to S3, then shuts down
- **DataFusion OpenSearch** — downloads pre-built distribution from S3, runs with PPL queries (via `/_plugins/_ppl`)
- **Lucene OpenSearch** — downloads pre-built distribution from S3, runs with DSL queries (via `/_search`), no plugins
- **Benchmark Runner** — runs OpenSearch Benchmark (OSB) and correctness tests against both engines, uploads results to S3

---

## Quick Start

### 1. Install dependencies

```bash
npm install
```

### 2. Bootstrap CDK (first time only)

```bash
npx cdk bootstrap
```

### 3. Deploy

```bash
# Single-node (default)
npx cdk deploy

# Multi-node (3 managers + N data nodes per engine, with ALB)
npx cdk deploy -c clusterMode=multi -c dataNodeCount=1
```

On first run, `setup-env.sh` runs automatically to discover your VPC, create a security group, key pair, and S3 bucket.

### 4. Monitor progress

CDK outputs include SSH and log commands. The builder takes ~30 min to build both engines. Runtime instances poll S3 and start OpenSearch once the tar.gz is available.

```bash
# Check builder progress
ssh -i ~/opensearch-benchmark.pem ec2-user@<builder-dns> "tail -f /var/log/user-data.log"

# Check benchmark progress
ssh -i ~/opensearch-benchmark.pem ec2-user@<benchmark-dns> "tail -f ~/benchmark-run.log"
```

All logs also stream to CloudWatch (persist after instance termination).

### 5. Destroy

```bash
npx cdk destroy --force
```

---

## Architecture

### Single-node mode (`npx cdk deploy`)

| Instance | Type | What it does |
|---|---|---|
| Builder | `r7g.2xlarge` | Builds both engines, uploads tar.gz to S3, shuts down |
| DataFusion | `r7g.2xlarge` | Downloads tar.gz, runs OpenSearch with DataFusion + SQL plugins |
| Lucene | `r7g.2xlarge` | Downloads tar.gz, runs vanilla OpenSearch (no plugins) |
| Benchmark | `m7g.medium` | Runs OSB benchmarks + correctness tests against both |

### Multi-node mode (`npx cdk deploy -c clusterMode=multi -c dataNodeCount=1`)

| Instance | Count | Role |
|---|---|---|
| Builder | 1 | Builds both engines, uploads tar.gz to S3 |
| DataFusion Seed Manager | 1 | Bootstraps DataFusion cluster |
| DataFusion Managers | 2 | Cluster manager redundancy |
| DataFusion Data Nodes | N (configurable) | Stores data, serves queries |
| DataFusion ALB | 1 | Internal load balancer → data nodes on port 9200 |
| Lucene Seed Manager | 1 | Bootstraps Lucene cluster |
| Lucene Managers | 2 | Cluster manager redundancy |
| Lucene Data Nodes | N (configurable) | Stores data, serves queries |
| Lucene ALB | 1 | Internal load balancer → data nodes on port 9200 |
| Benchmark | 1 | Runs benchmarks against both ALBs |

Multi-node uses EC2 tag-based discovery (`discovery.seed_providers: ec2`). Each engine has its own cluster tag so they don't discover each other.

---

## S3 Structure

```
s3://opensearch-codeguru-<account-id>/
├── builds/
│   ├── opensearch-datafusion.tar.gz    ← Pre-built DataFusion + all plugins
│   ├── opensearch-lucene.tar.gz        ← Pre-built Lucene (no plugins)
│   └── BUILD_COMPLETE                  ← Marker file
├── benchmark-results/
│   ├── datafusion/<run-id>.csv
│   └── lucene/<run-id>.csv
├── correctness-results/
│   ├── datafusion/<run-id>.json
│   └── lucene/<run-id>.json
└── profiler/
    ├── datafusion/<instance-id>/cpu_<timestamp>.html
    └── lucene/<instance-id>/cpu_<timestamp>.html
```

---

## Manual Benchmark Commands

SSH into the benchmark instance and run benchmarks manually:

```bash
ssh -i ~/opensearch-benchmark.pem ec2-user@<benchmark-dns>
```

### Run all benchmarks + correctness tests

```bash
nohup bash ~/opensearch-test-automation/run-all.sh > ~/benchmark-run.log 2>&1 &
tail -f ~/benchmark-run.log
```

### Run individual benchmarks

```bash
# DataFusion (single-node — use private IP)
bash ~/opensearch-test-automation/benchmark/run-benchmark.sh \
  --host <datafusion-private-ip> \
  --engine datafusion \
  --workload ~/datafusion-workloads/clickbench

# DataFusion (multi-node — use ALB DNS)
bash ~/opensearch-test-automation/benchmark/run-benchmark.sh \
  --host <datafusion-alb-dns> \
  --engine datafusion \
  --workload ~/datafusion-workloads/clickbench

# Lucene (single-node — use private IP)
bash ~/opensearch-test-automation/benchmark/run-benchmark.sh \
  --host <lucene-private-ip> \
  --engine lucene \
  --workload ~/lucene-workloads/clickbench

# Lucene (multi-node — use ALB DNS)
bash ~/opensearch-test-automation/benchmark/run-benchmark.sh \
  --host <lucene-alb-dns> \
  --engine lucene \
  --workload ~/lucene-workloads/clickbench
```

### Check cluster health (multi-node)

```bash
# From the benchmark instance
curl -s http://<alb-dns>:9200/_cat/nodes?v
curl -s http://<alb-dns>:9200/_cluster/health?pretty
```

---

## Configuration

### CLI Flags

| Flag | Default | Description |
|---|---|---|
| `-c clusterMode=multi` | `single` | Enable multi-node cluster mode |
| `-c dataNodeCount=3` | `3` | Number of data nodes per engine (multi-node only) |
| `-c datafusionBranch=<branch>` | `feature/datafusion` | DataFusion OpenSearch branch |
| `-c datafusionRepo=<url>` | `opensearch-project/OpenSearch` | DataFusion OpenSearch repo |

### .env Variables

Auto-generated by `setup-env.sh`. Key variables:

| Variable | Default | Description |
|---|---|---|
| `INSTANCE_TYPE` | `r7g.2xlarge` | OpenSearch instance type |
| `JVM_HEAP` | `8g` | JVM heap size |
| `LUCENE_ENABLED` | `true` | Set to `false` to skip Lucene |
| `BENCHMARK_ENABLED` | `true` | Set to `false` to skip benchmark |
| `DATAFUSION_BRANCH` | `feature/datafusion` | Branch to build |
| `LUCENE_BRANCH` | `main` | Branch to build |

---

## CloudWatch Logs

| Log Group | Source | Content |
|---|---|---|
| `/opensearch/builder/user-data` | Builder instance | Build progress (persists after shutdown) |
| `/opensearch/datafusion/user-data` | DataFusion instances | Setup/download progress |
| `/opensearch/datafusion/runtime` | DataFusion instances | OpenSearch runtime logs |
| `/opensearch/lucene/user-data` | Lucene instances | Setup/download progress |
| `/opensearch/lucene/runtime` | Lucene instances | OpenSearch runtime logs |
| `/opensearch/benchmark/user-data` | Benchmark instance | OSB setup progress |
| `/opensearch/benchmark/run` | Benchmark instance | Benchmark execution logs |

---

## Security

- OpenSearch binds to `_site_` (private IP only) — not reachable from public internet
- ALBs are internal (`internetFacing: false`) — VPC only
- Security group: SSH (22) open to `0.0.0.0/0`, all other traffic via SG self-referencing rule only
- No port 9200/9300 CIDR rules — prevents Palisade from flagging open ElasticSearch endpoints
- SG imported as `mutable: false` — CDK cannot add ingress rules (prevents ALB auto-adding `0.0.0.0/0:9200`)

---

## Troubleshooting

**CDK deploy fails with "Not logged in to AWS"**
```bash
ada credentials update --account <ACCOUNT_ID> --role Admin
```

**Termination protection blocks destroy**
```bash
for ID in $(aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-name,Values=OpenSearchCodeGuruStack" --query 'Reservations[].Instances[].InstanceId' --output text --region us-east-1); do
  aws ec2 modify-instance-attribute --instance-id $ID --no-disable-api-termination --region us-east-1 2>/dev/null
done
npx cdk destroy --force
```

**Stack stuck in DELETE_FAILED**
```bash
aws cloudformation delete-stack --stack-name OpenSearchCodeGuruStack --retain-resources <failed-resource-id> --region us-east-1
```

**Benchmark fails with 502 Bad Gateway (multi-node)**
The cluster hasn't formed yet. Wait for all nodes to download the tar.gz and start OpenSearch. Check cluster health:
```bash
curl -s http://<alb-dns>:9200/_cluster/health?pretty
```

**Palisade isolates instances**
Ensure the security group has no port 9200/9300 CIDR rules. Delete `.env` and the old SG, then redeploy to get a clean SG with only SSH + self-referencing rules.
