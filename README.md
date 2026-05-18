# OpenSearch Performance & Correctness Test Infrastructure

One-command CDK stack that provisions EC2 instances to benchmark and compare three OpenSearch engine configurations: Parquet (DataFusion PPL), Lucene (vanilla DSL), and ParquetLucene (indexed parquet with lucene secondary). Supports both single-node and multi-node cluster modes.

- **Builder Instance** — builds both Parquet (sandbox + plugins + Rust native lib) and Lucene (vanilla) from source, uploads tar.gz to S3
- **Parquet OpenSearch** — pure parquet storage, PPL queries via DataFusion (`/_plugins/_ppl`)
- **Lucene OpenSearch** — vanilla OpenSearch, DSL queries via `/_search`
- **ParquetLucene OpenSearch** — parquet primary + lucene secondary, PPL queries via DataFusion
- **Benchmark Runner** — runs OSB benchmarks, correctness tests, field integrity checks, generates comparison dashboard, coordinates data uploads to S3

---

## Quick Start

### 1. Clone the repo

```bash
git clone ssh://git.amazon.com/pkg/OpenSearchEC2WithCodeGuruCDK -b share/hxarishk/hxarishk/automating-performance-correctness-tests
cd OpenSearchEC2WithCodeGuruCDK
```

### 2. Install dependencies

```bash
npm install
```

### 3. Bootstrap CDK (first time only)

```bash
npx cdk bootstrap
```

### 4. Deploy

```bash
# Single-node (default)
npx cdk deploy

# Multi-node (3 managers + N data nodes per engine, with ALB)
npx cdk deploy -c clusterMode=multi -c dataNodeCount=3

# OpenSearch instances only (no benchmark — bring your own)
npx cdk deploy -c benchmarkEnabled=false
```

On first run, `setup-env.sh` runs automatically to discover your VPC, create a security group, key pair, and S3 bucket.

### 5. Monitor progress

CDK outputs include SSH and log commands. The builder takes ~30 min to build both engines. Runtime instances poll S3 and start OpenSearch once the tar.gz is available.

```bash
# Check builder progress
ssh -i ~/opensearch-benchmark.pem ec2-user@<builder-dns> "tail -f /var/log/user-data.log"

# Check benchmark progress
ssh -i ~/opensearch-benchmark.pem ec2-user@<benchmark-dns> "tail -f ~/benchmark-run.log"
```

All logs also stream to CloudWatch (persist after instance termination).

### 6. Destroy

```bash
npx cdk destroy --force
```

---

## Architecture

### Single-node mode (`npx cdk deploy`)

| Instance | Type | JVM Heap | What it does |
|---|---|---|---|
| Builder | `r8g.2xlarge` | — | Builds both engines, uploads tar.gz to S3 |
| Parquet | `r8g.2xlarge` | 16g | Pure parquet storage, PPL queries via DataFusion |
| Lucene | `r8g.2xlarge` | 24g | Vanilla OpenSearch, DSL queries |
| ParquetLucene | `r8g.2xlarge` | 16g | Parquet + lucene secondary, PPL queries |
| Benchmark | `r8g.8xlarge` | — | Runs OSB, correctness, visualization, signals data upload |

### Multi-node mode (`npx cdk deploy -c clusterMode=multi -c dataNodeCount=3`)

Per engine: 3 cluster managers + N data nodes + internal ALB. Uses EC2 tag-based discovery.

---

## Configuration (`-c` Context Flags)

All settings are overridable via `cdk deploy -c key=value`. They can also be set as environment variables or in `.env`.

### Parquet Engine

| Flag | Env Var | Default | Description |
|---|---|---|---|
| `-c parquetRepo` | `PARQUET_REPO` | `opensearch-project/OpenSearch` | Git repo URL |
| `-c parquetBranch` | `PARQUET_BRANCH` | `main` | Branch to build |
| `-c parquetInstanceType` | `PARQUET_INSTANCE_TYPE` | `r8g.2xlarge` | EC2 instance type |
| `-c parquetEbsSizeGb` | `PARQUET_EBS_SIZE_GB` | `1000` | EBS volume size (GB) |
| `-c parquetEbsIops` | `PARQUET_EBS_IOPS` | `12000` | EBS provisioned IOPS |
| `-c parquetEbsThroughput` | `PARQUET_EBS_THROUGHPUT` | `500` | EBS throughput (MB/s) |
| `-c parquetJvmHeap` | `PARQUET_JVM_HEAP` | `16g` | JVM heap size |
| `-c parquetWorkloadRepo` | `PARQUET_WORKLOAD_REPO` | `HarishNarasimhanK/opensearch-benchmark-workloads` | OSB workload repo |
| `-c parquetWorkloadBranch` | `PARQUET_WORKLOAD_BRANCH` | `parquet` | Workload branch |

### Lucene Engine

| Flag | Env Var | Default | Description |
|---|---|---|---|
| `-c luceneEnabled` | `LUCENE_ENABLED` | `true` | Enable/disable Lucene |
| `-c luceneRepo` | `LUCENE_REPO` | `opensearch-project/OpenSearch` | Git repo URL |
| `-c luceneBranch` | `LUCENE_BRANCH` | `main` | Branch to build |
| `-c luceneInstanceType` | `LUCENE_INSTANCE_TYPE` | `r8g.2xlarge` | EC2 instance type |
| `-c luceneEbsSizeGb` | `LUCENE_EBS_SIZE_GB` | `1000` | EBS volume size (GB) |
| `-c luceneEbsIops` | `LUCENE_EBS_IOPS` | `12000` | EBS provisioned IOPS |
| `-c luceneEbsThroughput` | `LUCENE_EBS_THROUGHPUT` | `500` | EBS throughput (MB/s) |
| `-c luceneJvmHeap` | `LUCENE_JVM_HEAP` | `24g` | JVM heap size |
| `-c luceneWorkloadRepo` | `LUCENE_WORKLOAD_REPO` | `opensearch-project/opensearch-benchmark-workloads` | OSB workload repo |
| `-c luceneWorkloadBranch` | `LUCENE_WORKLOAD_BRANCH` | `main` | Workload branch |

### ParquetLucene Engine

| Flag | Env Var | Default | Description |
|---|---|---|---|
| `-c parquetLuceneEnabled` | `PARQUET_LUCENE_ENABLED` | `true` | Enable/disable ParquetLucene |
| `-c parquetLuceneInstanceType` | `PARQUET_LUCENE_INSTANCE_TYPE` | `r8g.2xlarge` | EC2 instance type |
| `-c parquetLuceneEbsSizeGb` | `PARQUET_LUCENE_EBS_SIZE_GB` | `1000` | EBS volume size (GB) |
| `-c parquetLuceneEbsIops` | `PARQUET_LUCENE_EBS_IOPS` | `12000` | EBS provisioned IOPS |
| `-c parquetLuceneEbsThroughput` | `PARQUET_LUCENE_EBS_THROUGHPUT` | `500` | EBS throughput (MB/s) |
| `-c parquetLuceneJvmHeap` | `PARQUET_LUCENE_JVM_HEAP` | `16g` | JVM heap size |
| `-c parquetLuceneWorkloadRepo` | `PARQUET_LUCENE_WORKLOAD_REPO` | `HarishNarasimhanK/opensearch-benchmark-workloads` | OSB workload repo |
| `-c parquetLuceneWorkloadBranch` | `PARQUET_LUCENE_WORKLOAD_BRANCH` | `indexed_parquet` | Workload branch |

### Benchmark Instance

| Flag | Env Var | Default | Description |
|---|---|---|---|
| `-c benchmarkEnabled` | `BENCHMARK_ENABLED` | `true` | Enable/disable benchmark |
| `-c benchmarkInstanceType` | `BENCHMARK_INSTANCE_TYPE` | `r8g.8xlarge` | EC2 instance type |
| `-c benchmarkEbsSizeGb` | `BENCHMARK_EBS_SIZE_GB` | `500` | EBS volume size (GB) |
| `-c benchmarkEbsIops` | `BENCHMARK_EBS_IOPS` | `12000` | EBS provisioned IOPS |
| `-c benchmarkEbsThroughput` | `BENCHMARK_EBS_THROUGHPUT` | `500` | EBS throughput (MB/s) |
| `-c testIterations` | `TEST_ITERATIONS` | `100` | Query iterations per benchmark |
| `-c ingestPercentage` | `INGEST_PERCENTAGE` | `0.001` | ClickBench ingest fraction (100 = full dataset) |

### Cluster & General

| Flag | Env Var | Default | Description |
|---|---|---|---|
| `-c clusterMode` | `CLUSTER_MODE` | `single` | `single` or `multi` |
| `-c dataNodeCount` | `DATA_NODE_COUNT` | `3` | Data nodes per engine (multi-node only) |
| `-c s3Bucket` | `S3_BUCKET` | `opensearch-codeguru` | S3 bucket for builds/results |
| `-c runIdPrefix` | `RUN_ID_PREFIX` | (empty) | Prefix for run IDs (e.g., `nightly`) |

---

## .env Variables

Auto-generated by `setup-env.sh`. These are networking/credentials that can't be passed via `-c` flags:

| Variable | Description |
|---|---|
| `CDK_ACCOUNT` | AWS account ID |
| `CDK_REGION` | AWS region |
| `VPC_ID` | VPC to deploy into |
| `SUBNET_ID` | Subnet for instances |
| `SUBNET_AZ` | Availability zone |
| `SECURITY_GROUP_ID` | Security group |
| `KEY_PAIR_NAME` | SSH key pair name |
| `METRICS_STORE_HOST` | Optional AOS domain for OSB telemetry persistence |

---

## Test Pipeline

Each deploy runs the following pipeline automatically (orchestrated by `run-all.sh`):

1. **Generate Run ID** — `run-YYYYMMDD_HHMMSS`
2. **Parquet benchmark** — OSB with `datafusion-ppl` test procedure (PPL queries)
3. **Parquet correctness** — 43 PPL queries, pass/fail per query
4. **Lucene benchmark** — OSB with `dsl-clickbench` test procedure (DSL queries)
5. **Lucene correctness** — DSL query pass/fail per query
6. **ParquetLucene benchmark** — OSB with `datafusion-ppl` test procedure (PPL queries, indexed_parquet)
7. **ParquetLucene correctness** — 43 PPL queries, pass/fail per query
8. **Field integrity check** — compares total count and null count per field between engines
9. **Comparison dashboard** — generates HTML with 5 Plotly charts comparing all engines
10. **Signal data upload** — data nodes upload their data folders to S3

All results go to `s3://bucket/runs/<RUN_ID>/`.

---

## Features

- **OSB Benchmark** — runs ClickBench workload via OpenSearch Benchmark against both engines with configurable iterations, shards, and ingest percentage
- **Correctness Testing** — executes all 43 PPL/DSL queries individually and captures pass/fail per query with raw responses
- **Field Integrity Check** — compares total doc count and null count per field between Lucene (DSL) and Parquet (PPL) across all 103 ClickBench fields
- **OSB Telemetry** — node-stats telemetry (CPU, memory, segments, merges, query cache) collected during benchmark runs; optionally persisted to an AOS metrics store domain
- **Async Profiler** — CPU flame graphs captured every 5 minutes on each OpenSearch instance via async-profiler cron job
- **Data Upload** — after benchmarks complete, each data node tars and uploads its OpenSearch data directory (Parquet files for Parquet, Lucene segments for Lucene) to S3 for post-mortem analysis
- **CloudWatch Metrics + Logs** — system metrics (CPU, memory, disk, network) and all logs streamed to CloudWatch for real-time monitoring and post-termination access
- **vmstat Logging** — per-second memory stats (free/buff/cache) logged on each OpenSearch instance, streamed to CloudWatch, and visualized in the auto-created dashboard
- **Run Isolation** — each deploy generates a unique `RUN_ID`; all results are stored under `s3://bucket/runs/<RUN_ID>/` so runs never overwrite each other

---

## CloudWatch Logs

| Log Group | Source |
|---|---|
| `/opensearch/builder/user-data` | Builder instance build progress |
| `/opensearch/parquet/user-data` | Parquet setup progress |
| `/opensearch/parquet/runtime` | Parquet OpenSearch runtime logs |
| `/opensearch/parquet/vmstat` | Parquet vmstat memory stats |
| `/opensearch/lucene/user-data` | Lucene setup progress |
| `/opensearch/lucene/runtime` | Lucene OpenSearch runtime logs |
| `/opensearch/lucene/vmstat` | Lucene vmstat memory stats |
| `/opensearch/parquetLucene/user-data` | ParquetLucene setup progress |
| `/opensearch/parquetLucene/runtime` | ParquetLucene OpenSearch runtime logs |
| `/opensearch/parquetLucene/vmstat` | ParquetLucene vmstat memory stats |
| `/opensearch/benchmark/user-data` | Benchmark setup progress |
| `/opensearch/benchmark/run` | Full orchestrator output (run-all.sh) |
| `/opensearch/benchmark/parquet` | Parquet benchmark output |
| `/opensearch/benchmark/lucene` | Lucene benchmark output |
| `/opensearch/benchmark/parquetLucene` | ParquetLucene benchmark output |
