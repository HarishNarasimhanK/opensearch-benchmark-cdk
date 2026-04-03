# OpenSearch Performance & Correctness Test Infrastructure

One-command CDK stack that provisions 3 EC2 instances to benchmark and compare the DataFusion engine against vanilla Lucene OpenSearch.

- **DataFusion OpenSearch** — builds from `feature/datafusion` branch with the parquet-based DataFusion query engine
- **Lucene OpenSearch** — builds from `main` branch, vanilla Lucene (no plugins needed)
- **Benchmark Runner** — runs OpenSearch Benchmark (OSB) and correctness tests against both engines, uploads results to S3

DataFusion is tested with **PPL queries** (via `/_plugins/_ppl`).
Lucene is tested with **DSL queries** (via `/_search`).

---

## Prerequisites

1. **Node.js 18+** and npm
   - Node 16 works if you remove the `throughput` parameter on line 93 of `lib/opensearch-codeguru-stack.ts`
2. **AWS CLI v2** — [install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
3. **jq** — [install guide](https://jqlang.github.io/jq/download/) (used by `deploy.sh` to parse CDK outputs)
4. **AWS credentials** configured for your target account
   - For Amazon employees: `ada credentials update --account <ACCOUNT_ID> --role Admin`
   - Or: `aws configure` / export environment variables

> No global AWS CDK install is needed — `aws-cdk` is included as a devDependency and runs via `npx`.

---

## Quick Start

### 1. Clone the repo

```bash
git clone ssh://git.amazon.com:2222/pkg/OpenSearchEC2WithCodeGuruCDK
cd OpenSearchEC2WithCodeGuruCDK
git fetch origin share/hxarishk/hxarishk/automating-performance-correctness-tests
git checkout hxarishk/automating-performance-correctness-tests
```

### 2. Install dependencies

```bash
npm install
```

### 3. Bootstrap CDK (first time only)

```bash
npx cdk bootstrap
```

This creates the CDK staging resources (S3 bucket, IAM roles) in your AWS account. Only needed once per account/region.

### 4. Deploy

```bash
npx cdk deploy
```

On first run, `setup-env.sh` runs automatically to:
- Discover your default VPC, subnet, and security group
- Create an EC2 key pair (`opensearch-benchmark`) and save the `.pem` to `$HOME/opensearch-benchmark.pem`
- Create an S3 bucket for results (`opensearch-codeguru-<account-id>`)
- Write all config to `.env`

After setup, CDK deploys all 3 instances in parallel. The deploy takes ~4 minutes. The OpenSearch builds take ~25 minutes after that.

### 5. Monitor progress

CDK outputs include ready-to-copy log commands:

```
OpenSearchCodeGuruStack.DataFusionBuildLog = ssh -i ~/opensearch-benchmark.pem ec2-user@... "tail -f /var/log/user-data.log"
OpenSearchCodeGuruStack.LuceneBuildLog = ssh -i ~/opensearch-benchmark.pem ec2-user@... "tail -f /var/log/user-data.log"
OpenSearchCodeGuruStack.BenchmarkRunLog = ssh -i ~/opensearch-benchmark.pem ec2-user@... "tail -f ~/benchmark-run.log"
```

### 6. Results

Results are uploaded to S3 automatically:

```
s3://<bucket>/benchmark-results/datafusion/   — OSB benchmark CSV (latency, throughput)
s3://<bucket>/benchmark-results/lucene/       — OSB benchmark CSV
s3://<bucket>/correctness-results/datafusion/ — PPL query responses (JSON)
s3://<bucket>/correctness-results/lucene/     — DSL query responses (JSON)
s3://<bucket>/profiler/datafusion/            — CPU flamegraphs (HTML)
s3://<bucket>/profiler/lucene/                — CPU flamegraphs (HTML)
```

Download results:
```bash
aws s3 cp s3://opensearch-codeguru-<account-id>/benchmark-results/ ./results/ --recursive
```

---

## Architecture

| Instance | Type | EBS | What it does |
|---|---|---|---|
| DataFusion OpenSearch | `r7g.2xlarge` | 100 GB gp3 | Builds OpenSearch from `feature/datafusion`, installs SQL + DataFusion plugins, runs async-profiler |
| Lucene OpenSearch | `r7g.2xlarge` | 100 GB gp3 | Builds vanilla OpenSearch from `main`, no plugins, runs async-profiler |
| Benchmark Runner | `m7g.medium` | 500 GB gp3 | Installs OSB, runs benchmarks and correctness tests against both engines |

All instances are ARM64 (Amazon Linux 2023), share the same VPC/subnet/security group, and communicate via private IP on port 9200.

---

## SSH Key Pair

On first run, `setup-env.sh` creates an EC2 key pair called `opensearch-benchmark` and saves the private key to `$HOME/opensearch-benchmark.pem`.

**Keep this file safe — it cannot be downloaded again.** If lost, delete the key pair in AWS and re-run `setup-env.sh`:

```bash
aws ec2 delete-key-pair --key-name opensearch-benchmark --region us-east-1
rm -f .env
npx cdk deploy   # re-runs setup-env.sh, creates new key pair
```

---

## Configuration

All config is in `.env` (auto-generated). Override by uncommenting and editing values.

### Networking (auto-discovered)

| Variable | Description |
|---|---|
| `CDK_ACCOUNT` | AWS account ID |
| `CDK_REGION` | AWS region (default: `us-east-1`) |
| `VPC_ID` | VPC to launch instances in |
| `SUBNET_ID` | Public subnet (must auto-assign public IPs) |
| `SUBNET_AZ` | Subnet availability zone |
| `SECURITY_GROUP_ID` | Security group allowing SSH (22) and OpenSearch (9200) |
| `KEY_PAIR_NAME` | EC2 key pair name |
| `S3_BUCKET` | S3 bucket for all results and flamegraphs |

### DataFusion OpenSearch

| Variable | Default | Description |
|---|---|---|
| `DATAFUSION_REPO` | `opensearch-project/OpenSearch` | Git repo URL |
| `DATAFUSION_BRANCH` | `feature/datafusion` | Branch to build |
| `DATAFUSION_SQL_REPO` | `bharath-techie/sql` | SQL plugin repo |
| `DATAFUSION_SQL_BRANCH` | `substrait-plan` | SQL plugin branch |

### Lucene OpenSearch

| Variable | Default | Description |
|---|---|---|
| `LUCENE_REPO` | `opensearch-project/OpenSearch` | Git repo URL |
| `LUCENE_BRANCH` | `main` | Branch to build |
| `LUCENE_ENABLED` | `true` | Set to `false` to skip Lucene instance |

### Instance Config

| Variable | Default | Description |
|---|---|---|
| `INSTANCE_TYPE` | `r7g.2xlarge` | OpenSearch instance type |
| `EBS_SIZE_GB` | `100` | OpenSearch root volume size |
| `EBS_IOPS` | `3000` | gp3 IOPS |
| `EBS_THROUGHPUT` | `125` | gp3 throughput (MB/s) |
| `JVM_HEAP` | `8g` | OpenSearch JVM heap size |

### Benchmark Config

| Variable | Default | Description |
|---|---|---|
| `BENCHMARK_ENABLED` | `true` | Set to `false` to skip benchmark instance |
| `BENCHMARK_INSTANCE_TYPE` | `m7g.medium` | Benchmark instance type |
| `BENCHMARK_EBS_SIZE_GB` | `500` | Benchmark root volume (for clickbench dataset) |
| `WORKLOAD_REPO` | `HarishNarasimhanK/opensearch-benchmark-workloads` | Workload repo for DataFusion |
| `WORKLOAD_BRANCH` | `main` | Workload branch |

### CLI Overrides

You can override the DataFusion repo/branch inline without editing `.env`:

```bash
npx cdk deploy -c datafusionRepo=https://github.com/alchemist51/OpenSearch.git -c datafusionBranch=feature/datafusion
```

> Note: `-c` flags override both `.env` and defaults. Only `datafusionRepo` and `datafusionBranch` support `-c` flags. For other parameters, edit `.env`.

### Changing Branches / Repos

There are 3 ways to customize which OpenSearch code gets built, listed in priority order:

**Option 1: CLI flags (highest priority, no file changes)**
```bash
npx cdk deploy -c datafusionRepo=https://github.com/your-fork/OpenSearch.git -c datafusionBranch=your-branch
```

**Option 2: Edit `.env` (persists across deploys)**

After the first `npx cdk deploy`, a `.env` file is auto-generated. Uncomment and edit:
```env
DATAFUSION_REPO=https://github.com/your-fork/OpenSearch.git
DATAFUSION_BRANCH=your-branch
DATAFUSION_SQL_REPO=https://github.com/your-fork/sql.git
DATAFUSION_SQL_BRANCH=your-branch

LUCENE_REPO=https://github.com/opensearch-project/OpenSearch.git
LUCENE_BRANCH=main
```

Then redeploy: `npx cdk deploy`

**Option 3: Edit defaults in `bin/app.ts` (permanent change)**

Edit the default values directly in `bin/app.ts`:
```typescript
// Line 41-45 — DataFusion config
const branch = ... || "feature/datafusion";           // ← change this
const opensearchRepo = ... || "https://github.com/opensearch-project/OpenSearch.git";  // ← or this
const sqlPluginRepo = ... || "https://github.com/bharath-techie/sql.git";
const sqlPluginBranch = ... || "substrait-plan";

// Line 48-50 — Lucene config
const luceneBranch = ... || "main";                   // ← change this
const luceneRepo = ... || "https://github.com/opensearch-project/OpenSearch.git";
```

---

## Logs

### DataFusion OpenSearch Instance

| Log | Command | Description |
|---|---|---|
| Build progress | `tail -f /var/log/user-data.log` | Clone, gradle, plugin install, OpenSearch start |
| OpenSearch runtime | `tail -f ~/datafusion-opensearch-run.log` | Errors, queries, GC |
| Profiler cron | `tail -f ~/profile-cron.log` | Async-profiler output |

### Lucene OpenSearch Instance

| Log | Command | Description |
|---|---|---|
| Build progress | `tail -f /var/log/user-data.log` | Clone, gradle, OpenSearch start |
| OpenSearch runtime | `tail -f ~/lucene-opensearch-run.log` | Errors, queries, GC |
| Profiler cron | `tail -f ~/profile-cron.log` | Async-profiler output |

### Benchmark Instance

| Log | Command | Description |
|---|---|---|
| Setup progress | `tail -f /var/log/user-data.log` | pip install, git clone |
| Benchmark + correctness | `tail -f ~/benchmark-run.log` | Full test execution |
| DataFusion benchmark | `tail -f ~/benchmark-datafusion.log` | OSB output for DataFusion |
| Lucene benchmark | `tail -f ~/benchmark-lucene.log` | OSB output for Lucene |
| DataFusion correctness | `tail -f ~/correctness-datafusion.log` | PPL query results |
| Lucene correctness | `tail -f ~/correctness-lucene.log` | DSL query results |

---

## Useful Commands

```bash
# Deploy / Destroy
npx cdk deploy                  # Deploy all 3 instances
npx cdk destroy --force         # Tear down everything
npx cdk synth                   # Preview CloudFormation template

# On the OpenSearch instances
curl -s http://localhost:9200                  # Health check
curl -s http://localhost:9200/_cat/indices?v   # List indices

# On the Benchmark instance
bash ~/opensearch-test-automation/run-all.sh                                    # Re-run everything
bash ~/opensearch-test-automation/benchmark/run-benchmark.sh --host <ip> --engine datafusion --workload ~/datafusion-workloads/clickbench
bash ~/opensearch-test-automation/correctness/run-datafusion-correctness-test.sh <ip> datafusion
bash ~/opensearch-test-automation/correctness/run-lucene-correctness-test.sh <ip> lucene ~/lucene-workloads/clickbench/operations/dsl.json

# Download results from S3
aws s3 ls s3://opensearch-codeguru-<account-id>/ --recursive
aws s3 cp s3://opensearch-codeguru-<account-id>/benchmark-results/ ./results/ --recursive
```

---

## Troubleshooting

**CDK deploy fails with "Not logged in to AWS"**
```bash
ada credentials update --account <ACCOUNT_ID> --role Admin
# or export AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN
```

**CDK deploy fails with "cdk bootstrap" error**
```bash
npx cdk bootstrap   # only needed once per account/region
```

**Node 16 compatibility**
Remove the `throughput` parameter on line 93 of `lib/opensearch-codeguru-stack.ts`. Use `npx cdk bootstrap` (not `cdk bootstrap`) to use the local CDK version.

**Benchmark timed out waiting for OpenSearch**
The OpenSearch build takes ~25 minutes. The benchmark waits up to 50 minutes. If it still times out, SSH into the OpenSearch instance and check `tail -f /var/log/user-data.log` for build errors.

**"Writer already exists" error on DataFusion**
Known bug in the Parquet writer on 3.3.0-SNAPSHOT when bulk indexing with `index.sort` fields. The benchmark uses `ingest_percentage: 0.001` (1000 docs) to work around this.

**Lucene version mismatch (job-scheduler)**
Not applicable anymore — the Lucene instance no longer installs any plugins. DSL queries go directly to `/_search`.
