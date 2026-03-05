#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import * as dotenv from "dotenv";
import { OpenSearchCodeGuruStack } from "../lib/opensearch-codeguru-stack";

dotenv.config();

const app = new cdk.App();

const account = process.env.CDK_ACCOUNT || process.env.CDK_DEFAULT_ACCOUNT;
const region = process.env.CDK_REGION || process.env.CDK_DEFAULT_REGION || "us-east-1";
const branch = process.env.OPENSEARCH_BRANCH || "feature/datafusion";
const vpcId = process.env.VPC_ID;
const subnetId = process.env.SUBNET_ID;
const subnetAz = process.env.SUBNET_AZ;
const keyPairName = process.env.KEY_PAIR_NAME;
const securityGroupId = process.env.SECURITY_GROUP_ID;
const sqlPluginRepo = process.env.SQL_PLUGIN_REPO || "https://github.com/bharath-techie/sql.git";
const sqlPluginBranch = process.env.SQL_PLUGIN_BRANCH || "substrait-plan";

if (!vpcId || !subnetId || !subnetAz || !keyPairName || !securityGroupId) {
  throw new Error("VPC_ID, SUBNET_ID, SUBNET_AZ, SECURITY_GROUP_ID, and KEY_PAIR_NAME must be set in .env");
}

new OpenSearchCodeGuruStack(app, "OpenSearchCodeGuruStack", {
  env: { account, region },
  branch,
  vpcId,
  subnetId,
  subnetAz,
  securityGroupId,
  keyPairName,
  sqlPluginRepo,
  sqlPluginBranch,
});
