import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as s3assets from "aws-cdk-lib/aws-s3-assets";
import { Construct } from "constructs";
import * as fs from "fs";
import * as path from "path";

interface OpenSearchCodeGuruStackProps extends cdk.StackProps {
  branch: string;
  opensearchRepo: string;
  vpcId: string;
  subnetId: string;
  subnetAz: string;
  securityGroupId: string;
  keyPairName: string;
  sqlPluginRepo: string;
  sqlPluginBranch: string;
  s3ProfileBucket: string;
  instanceType: string;
  ebsSizeGb: number;
  ebsIops: number;
  ebsThroughput: number;
  jvmHeap: string;
  benchmarkEnabled: boolean;
  benchmarkInstanceType: string;
  benchmarkEbsSizeGb: number;
  workloadRepo: string;
  workloadBranch: string;
  luceneEnabled: boolean;
  luceneRepo: string;
  luceneBranch: string;
}

export class OpenSearchCodeGuruStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: OpenSearchCodeGuruStackProps) {
    super(scope, id, props);

    const { branch, opensearchRepo, vpcId, subnetId, subnetAz, securityGroupId, keyPairName,
      sqlPluginRepo, sqlPluginBranch, s3ProfileBucket, instanceType, ebsSizeGb, ebsIops,
      ebsThroughput, jvmHeap, benchmarkEnabled, benchmarkInstanceType, benchmarkEbsSizeGb,
      workloadRepo, workloadBranch, luceneEnabled, luceneRepo, luceneBranch } = props;

    // --- Look up existing VPC and Subnet ---
    const vpc = ec2.Vpc.fromLookup(this, "ExistingVpc", { vpcId });
    const subnet = ec2.Subnet.fromSubnetAttributes(this, "ExistingSubnet", {
      subnetId, availabilityZone: subnetAz,
    });
    const sg = ec2.SecurityGroup.fromSecurityGroupId(this, "ExistingSG", securityGroupId);

    // --- IAM role with S3 and CloudWatch permissions ---
    const role = new iam.Role(this, "OpenSearchInstanceRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonS3FullAccess"),
        iam.ManagedPolicy.fromAwsManagedPolicyName("CloudWatchAgentServerPolicy"),
      ],
    });
    const instanceProfile = new iam.InstanceProfile(this, "OpenSearchInstanceProfile", { role });
    const keyPair = ec2.KeyPair.fromKeyPairName(this, "ExistingKeyPair", keyPairName);

    // --- Upload automation scripts to S3 as a CDK asset ---
    const scriptsAsset = new s3assets.Asset(this, "AutomationScripts", {
      path: path.join(__dirname, "..", "opensearch-test-automation"),
      exclude: [".git", ".git/**"],
    });
    scriptsAsset.grantRead(role);
    const scriptsS3Path = `s3://${scriptsAsset.s3BucketName}/${scriptsAsset.s3ObjectKey}`;

    // --- Helper: create an instance with a launch template ---
    const createInstance = (nodeId: string, ltId: string, userDataScript: string, instType: string, ebsSize: number, ebsIopsVal?: number, ebsThroughputVal?: number): ec2.Instance => {
      const ud = ec2.UserData.forLinux();
      ud.addCommands(userDataScript);

      const ltProps: ec2.LaunchTemplateProps = {
        instanceType: new ec2.InstanceType(instType),
        machineImage: ec2.MachineImage.latestAmazonLinux2023({ cpuType: ec2.AmazonLinuxCpuType.ARM_64 }),
        securityGroup: sg, instanceProfile, userData: ud, keyPair,
        blockDevices: [{
          deviceName: "/dev/xvda",
          volume: ec2.BlockDeviceVolume.ebs(ebsSize, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            ...(ebsIopsVal ? { iops: ebsIopsVal } : {}),
            ...(ebsThroughputVal ? { throughput: ebsThroughputVal } : {}),
          }),
        }],
      };

      const lt = new ec2.LaunchTemplate(this, ltId, ltProps);

      const inst = new ec2.Instance(this, nodeId, {
        vpc, instanceType: new ec2.InstanceType(instType),
        machineImage: ec2.MachineImage.latestAmazonLinux2023({ cpuType: ec2.AmazonLinuxCpuType.ARM_64 }),
        vpcSubnets: { subnets: [subnet] },
      });

      const cfn = inst.node.defaultChild as cdk.CfnResource;
      cfn.addPropertyOverride("LaunchTemplate", { LaunchTemplateId: lt.launchTemplateId, Version: lt.latestVersionNumber });
      cfn.addPropertyOverride("DisableApiTermination", false);
      cfn.addPropertyDeletionOverride("SecurityGroupIds");
      cfn.addPropertyDeletionOverride("UserData");
      cfn.addPropertyDeletionOverride("IamInstanceProfile");
      cfn.addPropertyDeletionOverride("KeyName");

      return inst;
    };

    // =========================================================================
    // Builder Instance — builds both DataFusion and Lucene, uploads tar.gz to S3
    // =========================================================================
    const builderScript = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data-builder.sh"), "utf-8")
      .replace(/\{\{BRANCH\}\}/g, branch)
      .replace(/\{\{OPENSEARCH_REPO\}\}/g, opensearchRepo)
      .replace(/\{\{SQL_PLUGIN_REPO\}\}/g, sqlPluginRepo)
      .replace(/\{\{SQL_PLUGIN_BRANCH\}\}/g, sqlPluginBranch)
      .replace(/\{\{LUCENE_BRANCH\}\}/g, luceneBranch)
      .replace(/\{\{LUCENE_REPO\}\}/g, luceneRepo)
      .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket);

    const builderInstance = createInstance("BuilderInstance", "BuilderLaunchTemplate", builderScript, instanceType, ebsSizeGb, ebsIops, ebsThroughput);

    new cdk.CfnOutput(this, "A1BuilderSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${builderInstance.instancePublicDnsName}` });
    new cdk.CfnOutput(this, "A2BuilderLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${builderInstance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
    new cdk.CfnOutput(this, "A3BuilderInstanceId", { value: builderInstance.instanceId });

    // =========================================================================
    // DataFusion OpenSearch Instance — downloads pre-built tar.gz, starts OpenSearch
    // =========================================================================
    const datafusionScript = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data-datafusion.sh"), "utf-8")
      .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket)
      .replace(/\{\{JVM_HEAP\}\}/g, jvmHeap)
      .replace(/\{\{SCRIPTS_S3_PATH\}\}/g, scriptsS3Path);

    const datafusionInstance = createInstance("OpenSearchInstance", "OpenSearchLaunchTemplate", datafusionScript, instanceType, ebsSizeGb, ebsIops, ebsThroughput);

    new cdk.CfnOutput(this, "B1DataFusionSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${datafusionInstance.instancePublicDnsName}` });
    new cdk.CfnOutput(this, "B2DataFusionSetupLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${datafusionInstance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
    new cdk.CfnOutput(this, "B3DataFusionRuntimeLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${datafusionInstance.instancePublicDnsName} "tail -f ~/datafusion-opensearch-run.log"` });
    new cdk.CfnOutput(this, "B4DataFusionInstanceId", { value: datafusionInstance.instanceId });
    new cdk.CfnOutput(this, "B5DataFusionPrivateIp", { value: datafusionInstance.instancePrivateIp });

    // =========================================================================
    // Lucene OpenSearch Instance (optional) — downloads pre-built tar.gz, starts OpenSearch
    // =========================================================================
    let lucenePrivateIp = "";
    if (luceneEnabled) {
      const luceneScript = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data-lucene.sh"), "utf-8")
        .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket)
        .replace(/\{\{JVM_HEAP\}\}/g, jvmHeap)
        .replace(/\{\{SCRIPTS_S3_PATH\}\}/g, scriptsS3Path);

      const luceneInstance = createInstance("LuceneInstance", "LuceneLaunchTemplate", luceneScript, instanceType, ebsSizeGb, ebsIops, ebsThroughput);
      lucenePrivateIp = luceneInstance.instancePrivateIp;

      new cdk.CfnOutput(this, "C1LuceneSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${luceneInstance.instancePublicDnsName}` });
      new cdk.CfnOutput(this, "C2LuceneSetupLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${luceneInstance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
      new cdk.CfnOutput(this, "C3LuceneRuntimeLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${luceneInstance.instancePublicDnsName} "tail -f ~/lucene-opensearch-run.log"` });
      new cdk.CfnOutput(this, "C4LuceneInstanceId", { value: luceneInstance.instanceId });
      new cdk.CfnOutput(this, "C5LucenePrivateIp", { value: luceneInstance.instancePrivateIp });
    }

    // =========================================================================
    // Benchmark Instance (optional) — runs OSB + correctness tests
    // =========================================================================
    if (benchmarkEnabled) {
      const benchmarkScript = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data-benchmark.sh"), "utf-8")
        .replace(/\{\{WORKLOAD_REPO\}\}/g, workloadRepo)
        .replace(/\{\{WORKLOAD_BRANCH\}\}/g, workloadBranch)
        .replace(/\{\{DATAFUSION_PRIVATE_IP\}\}/g, datafusionInstance.instancePrivateIp)
        .replace(/\{\{LUCENE_PRIVATE_IP\}\}/g, lucenePrivateIp)
        .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket)
        .replace(/\{\{SCRIPTS_S3_PATH\}\}/g, scriptsS3Path);

      const benchmarkInstance = createInstance("BenchmarkInstance", "BenchmarkLaunchTemplate", benchmarkScript, benchmarkInstanceType, benchmarkEbsSizeGb);

      new cdk.CfnOutput(this, "D1BenchmarkSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${benchmarkInstance.instancePublicDnsName}` });
      new cdk.CfnOutput(this, "D2BenchmarkSetupLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${benchmarkInstance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
      new cdk.CfnOutput(this, "D3BenchmarkRunLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${benchmarkInstance.instancePublicDnsName} "tail -f ~/benchmark-run.log"` });
      new cdk.CfnOutput(this, "D4BenchmarkInstanceId", { value: benchmarkInstance.instanceId });
    }
  }
}
