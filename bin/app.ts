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

const account = process.env.CDK_ACCOUNT || process.env.CDK_DEFAULT_ACCOUNT;
const region = process.env.CDK_REGION || process.env.CDK_DEFAULT_REGION || "us-east-1";
const branch = process.env.OPENSEARCH_BRANCH || "feature/datafusion";
const opensearchRepo = process.env.OPENSEARCH_REPO || "https://github.com/opensearch-project/OpenSearch.git";
const vpcId = process.env.VPC_ID;
const subnetId = process.env.SUBNET_ID;
const subnetAz = process.env.SUBNET_AZ;
const keyPairName = process.env.KEY_PAIR_NAME;
const securityGroupId = process.env.SECURITY_GROUP_ID;
const sqlPluginRepo = process.env.SQL_PLUGIN_REPO || "https://github.com/bharath-techie/sql.git";
const sqlPluginBranch = process.env.SQL_PLUGIN_BRANCH || "substrait-plan";
const stackSuffix = process.env.STACK_SUFFIX || "";
const s3ProfileBucket = process.env.S3_PROFILE_BUCKET || "profiler-async";
const instanceType = process.env.INSTANCE_TYPE || "r7g.2xlarge";
const ebsSizeGb = parseInt(process.env.EBS_SIZE_GB || "100", 10);
const ebsIops = parseInt(process.env.EBS_IOPS || "3000", 10);
const ebsThroughput = parseInt(process.env.EBS_THROUGHPUT || "125", 10);
const jvmHeap = process.env.JVM_HEAP || "8g";
const benchmarkEnabled = (process.env.BENCHMARK_ENABLED || "true").toLowerCase() === "true";
const benchmarkInstanceType = process.env.BENCHMARK_INSTANCE_TYPE || "m7g.medium";
const benchmarkEbsSizeGb = parseInt(process.env.BENCHMARK_EBS_SIZE_GB || "500", 10);
const workloadRepo = process.env.WORKLOAD_REPO || "https://github.com/HarishNarasimhanK/opensearch-benchmark-workloads.git";
const workloadBranch = process.env.WORKLOAD_BRANCH || "main";
const stackName = stackSuffix
  ? `OpenSearchCodeGuruStack-${stackSuffix}`
  : "OpenSearchCodeGuruStack";

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
  sqlPluginRepo,
  sqlPluginBranch,
  stackSuffix,
  s3ProfileBucket,
  instanceType,
  ebsSizeGb,
  ebsIops,
  ebsThroughput,
  jvmHeap,
  benchmarkEnabled,
  benchmarkInstanceType,
  benchmarkEbsSizeGb,
  workloadRepo,
  workloadBranch,
});
