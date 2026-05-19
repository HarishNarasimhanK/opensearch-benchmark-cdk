#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import * as dotenv from "dotenv";
import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { OpenSearchCodeGuruStack } from "../lib/opensearch-codeguru-stack";

// Auto-run setup-env.sh if .env doesn't exist yet
const envFile = path.join(__dirname, "..", ".env");
if (!fs.existsSync(envFile)) {
  console.log("No .env file found — running setup-env.sh...\n");
  const setupScript = path.join(__dirname, "..", "scripts", "setup-env.sh");
  execSync(`bash "${setupScript}"`, { stdio: "inherit" });
  console.log("");
}

dotenv.config();

const app = new cdk.App();

// Helper: read from -c context flag, then env var, then default
const ctx = (key: string, envKey?: string, fallback?: string): string =>
  app.node.tryGetContext(key) || (envKey ? process.env[envKey] : undefined) || fallback || "";

// =============================================================================
// AWS / Networking
// =============================================================================
const account = process.env.CDK_ACCOUNT || process.env.CDK_DEFAULT_ACCOUNT;
const region = process.env.CDK_REGION || process.env.CDK_DEFAULT_REGION || "us-east-1";
const vpcId = process.env.VPC_ID;
const subnetId = process.env.SUBNET_ID;
const subnetAz = process.env.SUBNET_AZ;
const keyPairName = process.env.KEY_PAIR_NAME;
const securityGroupId = process.env.SECURITY_GROUP_ID;
const s3ProfileBucket = ctx("s3Bucket", "S3_BUCKET", "opensearch-codeguru");

// =============================================================================
// Parquet Engine — r8g.2xlarge, 16g heap, PPL queries via DataFusion
// =============================================================================
const parquetRepo = ctx("parquetRepo", "PARQUET_REPO", "https://github.com/opensearch-project/OpenSearch.git");
const parquetBranch = ctx("parquetBranch", "PARQUET_BRANCH", "main");
const parquetInstanceType = ctx("parquetInstanceType", "PARQUET_INSTANCE_TYPE", "r8g.2xlarge");
const parquetEbsSizeGb = parseInt(ctx("parquetEbsSizeGb", "PARQUET_EBS_SIZE_GB", "1000"), 10);
const parquetEbsIops = parseInt(ctx("parquetEbsIops", "PARQUET_EBS_IOPS", "12000"), 10);
const parquetEbsThroughput = parseInt(ctx("parquetEbsThroughput", "PARQUET_EBS_THROUGHPUT", "500"), 10);
const parquetJvmHeap = ctx("parquetJvmHeap", "PARQUET_JVM_HEAP", "16g");
const parquetWorkloadRepo = ctx("parquetWorkloadRepo", "PARQUET_WORKLOAD_REPO", "https://github.com/HarishNarasimhanK/opensearch-benchmark-workloads.git");
const parquetWorkloadBranch = ctx("parquetWorkloadBranch", "PARQUET_WORKLOAD_BRANCH", "parquet");

// =============================================================================
// Lucene Engine — r8g.2xlarge, 24g heap, DSL queries (vanilla OpenSearch)
// =============================================================================
const luceneEnabled = (ctx("luceneEnabled", "LUCENE_ENABLED", "true")).toLowerCase() === "true";
const luceneRepo = ctx("luceneRepo", "LUCENE_REPO", "https://github.com/opensearch-project/OpenSearch.git");
const luceneBranch = ctx("luceneBranch", "LUCENE_BRANCH", "main");
const luceneInstanceType = ctx("luceneInstanceType", "LUCENE_INSTANCE_TYPE", "r8g.2xlarge");
const luceneEbsSizeGb = parseInt(ctx("luceneEbsSizeGb", "LUCENE_EBS_SIZE_GB", "1000"), 10);
const luceneEbsIops = parseInt(ctx("luceneEbsIops", "LUCENE_EBS_IOPS", "12000"), 10);
const luceneEbsThroughput = parseInt(ctx("luceneEbsThroughput", "LUCENE_EBS_THROUGHPUT", "500"), 10);
const luceneJvmHeap = ctx("luceneJvmHeap", "LUCENE_JVM_HEAP", "32g");
const luceneWorkloadRepo = ctx("luceneWorkloadRepo", "LUCENE_WORKLOAD_REPO", "https://github.com/opensearch-project/opensearch-benchmark-workloads.git");
const luceneWorkloadBranch = ctx("luceneWorkloadBranch", "LUCENE_WORKLOAD_BRANCH", "main");

// =============================================================================
// ParquetLucene Engine — r8g.2xlarge, 16g heap, PPL queries (indexed_parquet)
// Same binary as Parquet, different index settings (parquet + lucene secondary)
// =============================================================================
const parquetLuceneEnabled = (ctx("parquetLuceneEnabled", "PARQUET_LUCENE_ENABLED", "true")).toLowerCase() === "true";
const parquetLuceneInstanceType = ctx("parquetLuceneInstanceType", "PARQUET_LUCENE_INSTANCE_TYPE", "r8g.2xlarge");
const parquetLuceneEbsSizeGb = parseInt(ctx("parquetLuceneEbsSizeGb", "PARQUET_LUCENE_EBS_SIZE_GB", "1000"), 10);
const parquetLuceneEbsIops = parseInt(ctx("parquetLuceneEbsIops", "PARQUET_LUCENE_EBS_IOPS", "12000"), 10);
const parquetLuceneEbsThroughput = parseInt(ctx("parquetLuceneEbsThroughput", "PARQUET_LUCENE_EBS_THROUGHPUT", "500"), 10);
const parquetLuceneJvmHeap = ctx("parquetLuceneJvmHeap", "PARQUET_LUCENE_JVM_HEAP", "16g");
const parquetLuceneWorkloadRepo = ctx("parquetLuceneWorkloadRepo", "PARQUET_LUCENE_WORKLOAD_REPO", "https://github.com/HarishNarasimhanK/opensearch-benchmark-workloads.git");
const parquetLuceneWorkloadBranch = ctx("parquetLuceneWorkloadBranch", "PARQUET_LUCENE_WORKLOAD_BRANCH", "indexed_parquet");

// =============================================================================
// Benchmark Instance — r8g.8xlarge, runs OSB + correctness + visualization
// =============================================================================
const benchmarkEnabled = (ctx("benchmarkEnabled", "BENCHMARK_ENABLED", "true")).toLowerCase() === "true";
const benchmarkInstanceType = ctx("benchmarkInstanceType", "BENCHMARK_INSTANCE_TYPE", "r8g.8xlarge");
const benchmarkEbsSizeGb = parseInt(ctx("benchmarkEbsSizeGb", "BENCHMARK_EBS_SIZE_GB", "500"), 10);
const benchmarkEbsIops = parseInt(ctx("benchmarkEbsIops", "BENCHMARK_EBS_IOPS", "12000"), 10);
const benchmarkEbsThroughput = parseInt(ctx("benchmarkEbsThroughput", "BENCHMARK_EBS_THROUGHPUT", "500"), 10);
const testIterations = parseInt(ctx("testIterations", "TEST_ITERATIONS", "100"), 10);
const ingestPercentage = parseFloat(ctx("ingestPercentage", "INGEST_PERCENTAGE", "0.001"));

// =============================================================================
// Cluster config
// =============================================================================
const clusterMode = ctx("clusterMode", "CLUSTER_MODE", "single");
const dataNodeCount = parseInt(ctx("dataNodeCount", "DATA_NODE_COUNT", "3"), 10);

// =============================================================================
// Metrics Store (AOS domain for OSB telemetry persistence)
// =============================================================================
const metricsStoreHost = process.env.METRICS_STORE_HOST || "";
const metricsStorePort = process.env.METRICS_STORE_PORT || "443";
const metricsStoreSecure = process.env.METRICS_STORE_SECURE || "True";

// =============================================================================
// Stack name & Run ID
// =============================================================================
const stackSuffix = app.node.tryGetContext("stackSuffix") || process.env.STACK_SUFFIX || "";
const stackName = stackSuffix
  ? `OpenSearchCodeGuruStack-${stackSuffix}`
  : "OpenSearchCodeGuruStack";

const runIdPrefix = ctx("runIdPrefix", "RUN_ID_PREFIX", "");
const now = new Date();
const timestamp = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, "0")}${String(now.getDate()).padStart(2, "0")}_${String(now.getHours()).padStart(2, "0")}${String(now.getMinutes()).padStart(2, "0")}${String(now.getSeconds()).padStart(2, "0")}`;
const runId = runIdPrefix ? `${runIdPrefix}-run-${timestamp}` : `run-${timestamp}`;

// =============================================================================
// Validation
// =============================================================================
if (!vpcId || !subnetId || !subnetAz || !keyPairName || !securityGroupId) {
  throw new Error("VPC_ID, SUBNET_ID, SUBNET_AZ, SECURITY_GROUP_ID, and KEY_PAIR_NAME must be set in .env");
}

// =============================================================================
// Deploy Stack
// =============================================================================
new OpenSearchCodeGuruStack(app, stackName, {
  env: { account, region },

  // Parquet
  parquetRepo,
  parquetBranch,
  parquetInstanceType,
  parquetEbsSizeGb,
  parquetEbsIops,
  parquetEbsThroughput,
  parquetJvmHeap,
  parquetWorkloadRepo,
  parquetWorkloadBranch,

  // Lucene
  luceneEnabled,
  luceneRepo,
  luceneBranch,
  luceneInstanceType,
  luceneEbsSizeGb,
  luceneEbsIops,
  luceneEbsThroughput,
  luceneJvmHeap,
  luceneWorkloadRepo,
  luceneWorkloadBranch,

  // ParquetLucene
  parquetLuceneEnabled,
  parquetLuceneInstanceType,
  parquetLuceneEbsSizeGb,
  parquetLuceneEbsIops,
  parquetLuceneEbsThroughput,
  parquetLuceneJvmHeap,
  parquetLuceneWorkloadRepo,
  parquetLuceneWorkloadBranch,

  // Benchmark
  benchmarkEnabled,
  benchmarkInstanceType,
  benchmarkEbsSizeGb,
  benchmarkEbsIops,
  benchmarkEbsThroughput,
  testIterations,
  ingestPercentage,

  // Networking
  vpcId,
  subnetId,
  subnetAz,
  securityGroupId,
  keyPairName,
  s3ProfileBucket,

  // Cluster
  clusterMode,
  dataNodeCount,

  // Metrics
  metricsStoreHost,
  metricsStorePort,
  metricsStoreSecure,

  // Run
  runId,
  runIdPrefix,
});
