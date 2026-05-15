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

// --- AWS / Networking ---
const account = process.env.CDK_ACCOUNT || process.env.CDK_DEFAULT_ACCOUNT;
const region = process.env.CDK_REGION || process.env.CDK_DEFAULT_REGION || "us-east-1";
const vpcId = process.env.VPC_ID;
const subnetId = process.env.SUBNET_ID;
const subnetAz = process.env.SUBNET_AZ;
const keyPairName = process.env.KEY_PAIR_NAME;
const securityGroupId = process.env.SECURITY_GROUP_ID;
const s3ProfileBucket = app.node.tryGetContext("s3Bucket") || process.env.S3_BUCKET || "opensearch-codeguru";

// --- Instance config ---
const instanceType = process.env.INSTANCE_TYPE || "r8g.2xlarge";
const ebsSizeGb = parseInt(process.env.EBS_SIZE_GB || "1000", 10);
const ebsIops = parseInt(process.env.EBS_IOPS || "12000", 10);
const ebsThroughput = parseInt(process.env.EBS_THROUGHPUT || "500", 10);
const jvmHeap = process.env.JVM_HEAP || "32g";
const parquetJvmHeap = "16g";

// --- Parquet OpenSearch config (upstream main) ---
const branch = app.node.tryGetContext("parquetBranch") || process.env.PARQUET_BRANCH || "main";
const opensearchRepo = app.node.tryGetContext("parquetRepo") || process.env.PARQUET_REPO || "https://github.com/opensearch-project/OpenSearch.git";

// --- Lucene OpenSearch config (no plugins — DSL queries only) ---
const luceneEnabled = (process.env.LUCENE_ENABLED || "true").toLowerCase() === "true";
const luceneRepo = app.node.tryGetContext("luceneRepo") || process.env.LUCENE_REPO || "https://github.com/opensearch-project/OpenSearch.git";
const luceneBranch = app.node.tryGetContext("luceneBranch") || process.env.LUCENE_BRANCH || "main";

// --- ParquetLucene config (same binary as Parquet, different workload) ---
const parquetLuceneEnabled = (app.node.tryGetContext("parquetLuceneEnabled") || process.env.PARQUET_LUCENE_ENABLED || "true").toLowerCase() === "true";
const parquetLuceneWorkloadRepo = app.node.tryGetContext("parquetLuceneWorkloadRepo") || process.env.PARQUET_LUCENE_WORKLOAD_REPO || "https://github.com/HarishNarasimhanK/opensearch-benchmark-workloads.git";
const parquetLuceneWorkloadBranch = app.node.tryGetContext("parquetLuceneWorkloadBranch") || process.env.PARQUET_LUCENE_WORKLOAD_BRANCH || "indexed_parquet";

// --- Cluster config ---
const clusterMode = app.node.tryGetContext("clusterMode") || process.env.CLUSTER_MODE || "single";
const dataNodeCount = parseInt(app.node.tryGetContext("dataNodeCount") || process.env.DATA_NODE_COUNT || "3", 10);

// --- Benchmark config ---
const benchmarkEnabled = (app.node.tryGetContext("benchmarkEnabled") || process.env.BENCHMARK_ENABLED || "true").toLowerCase() === "true";
const benchmarkInstanceType = process.env.BENCHMARK_INSTANCE_TYPE || "m7g.medium";
const benchmarkEbsSizeGb = parseInt(process.env.BENCHMARK_EBS_SIZE_GB || "500", 10);
const benchmarkEbsIops = parseInt(process.env.BENCHMARK_EBS_IOPS || "10000", 10);
const benchmarkEbsThroughput = parseInt(process.env.BENCHMARK_EBS_THROUGHPUT || "500", 10);
const parquetWorkloadRepo = app.node.tryGetContext("parquetWorkloadRepo") || process.env.PARQUET_WORKLOAD_REPO || "https://github.com/HarishNarasimhanK/opensearch-benchmark-workloads.git";
const parquetWorkloadBranch = app.node.tryGetContext("parquetWorkloadBranch") || process.env.PARQUET_WORKLOAD_BRANCH || "nightly";
const luceneWorkloadRepo = app.node.tryGetContext("luceneWorkloadRepo") || process.env.LUCENE_WORKLOAD_REPO || "https://github.com/opensearch-project/opensearch-benchmark-workloads.git";
const luceneWorkloadBranch = app.node.tryGetContext("luceneWorkloadBranch") || process.env.LUCENE_WORKLOAD_BRANCH || "main";
const testIterations = parseInt(app.node.tryGetContext("testIterations") || process.env.TEST_ITERATIONS || "100", 10);
const ingestPercentage = parseFloat(app.node.tryGetContext("ingestPercentage") || process.env.INGEST_PERCENTAGE || "0.001");

// --- Metrics store config ---
const metricsStoreHost = process.env.METRICS_STORE_HOST || "";
const metricsStorePort = process.env.METRICS_STORE_PORT || "443";
const metricsStoreSecure = process.env.METRICS_STORE_SECURE || "True";

// --- Stack name ---
const stackSuffix = process.env.STACK_SUFFIX || "";
const stackName = stackSuffix
  ? `OpenSearchCodeGuruStack-${stackSuffix}`
  : "OpenSearchCodeGuruStack";

// --- Run ID (generated at deploy time, shared across all instances) ---
const runIdPrefix = app.node.tryGetContext("runIdPrefix") || process.env.RUN_ID_PREFIX || "";
const now = new Date();
const timestamp = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, "0")}${String(now.getDate()).padStart(2, "0")}_${String(now.getHours()).padStart(2, "0")}${String(now.getMinutes()).padStart(2, "0")}${String(now.getSeconds()).padStart(2, "0")}`;
const runId = runIdPrefix ? `${runIdPrefix}-run-${timestamp}` : `run-${timestamp}`;

if (!vpcId || !subnetId || !subnetAz || !keyPairName || !securityGroupId) {
  throw new Error("VPC_ID, SUBNET_ID, SUBNET_AZ, SECURITY_GROUP_ID, and KEY_PAIR_NAME must be set in .env");
}

new OpenSearchCodeGuruStack(app, stackName, {
  env: { account, region },
  branch,
  opensearchRepo,
  vpcId,
  subnetId,
  subnetAz,
  securityGroupId,
  keyPairName,
  s3ProfileBucket,
  instanceType,
  ebsSizeGb,
  ebsIops,
  ebsThroughput,
  jvmHeap,
  parquetJvmHeap,
  benchmarkEnabled,
  benchmarkInstanceType,
  benchmarkEbsSizeGb,
  benchmarkEbsIops,
  benchmarkEbsThroughput,
  parquetWorkloadRepo,
  parquetWorkloadBranch,
  luceneWorkloadRepo,
  luceneWorkloadBranch,
  testIterations,
  ingestPercentage,
  luceneEnabled,
  luceneRepo,
  luceneBranch,
  parquetLuceneEnabled,
  parquetLuceneWorkloadRepo,
  parquetLuceneWorkloadBranch,
  clusterMode,
  dataNodeCount,
  metricsStoreHost,
  metricsStorePort,
  metricsStoreSecure,
  runId,
  runIdPrefix,
});
