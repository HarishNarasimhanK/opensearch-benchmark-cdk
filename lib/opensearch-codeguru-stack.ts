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
    const scriptsS3Path = `s3://${scriptsAsset.s3BucketName}/${scriptsAsset.s3ObjectKey}`;

    // --- DataFusion OpenSearch Instance ---
    const userDataScript = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data-datafusion.sh"), "utf-8")
      .replace(/\{\{BRANCH\}\}/g, branch)
      .replace(/\{\{OPENSEARCH_REPO\}\}/g, opensearchRepo)
      .replace(/\{\{SQL_PLUGIN_REPO\}\}/g, sqlPluginRepo)
      .replace(/\{\{SQL_PLUGIN_BRANCH\}\}/g, sqlPluginBranch)
      .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket)
      .replace(/\{\{JVM_HEAP\}\}/g, jvmHeap)
      .replace(/\{\{SCRIPTS_S3_PATH\}\}/g, scriptsS3Path);

    const userData = ec2.UserData.forLinux();
    userData.addCommands(userDataScript);

    const launchTemplate = new ec2.LaunchTemplate(this, "OpenSearchLaunchTemplate", {
      instanceType: new ec2.InstanceType(instanceType),
      machineImage: ec2.MachineImage.latestAmazonLinux2023({ cpuType: ec2.AmazonLinuxCpuType.ARM_64 }),
      securityGroup: sg, instanceProfile, userData, keyPair,
      blockDevices: [{
        deviceName: "/dev/xvda",
        volume: ec2.BlockDeviceVolume.ebs(ebsSizeGb, {
          volumeType: ec2.EbsDeviceVolumeType.GP3, iops: ebsIops, throughput: ebsThroughput,
        }),
      }],
    });

    const instance = new ec2.Instance(this, "OpenSearchInstance", {
      vpc, instanceType: new ec2.InstanceType(instanceType),
      machineImage: ec2.MachineImage.latestAmazonLinux2023({ cpuType: ec2.AmazonLinuxCpuType.ARM_64 }),
      vpcSubnets: { subnets: [subnet] },
    });

    const cfnInstance = instance.node.defaultChild as cdk.CfnResource;
    cfnInstance.addPropertyOverride("LaunchTemplate", {
      LaunchTemplateId: launchTemplate.launchTemplateId, Version: launchTemplate.latestVersionNumber,
    });
    cfnInstance.addPropertyDeletionOverride("SecurityGroupIds");
    cfnInstance.addPropertyDeletionOverride("UserData");
    cfnInstance.addPropertyDeletionOverride("IamInstanceProfile");
    cfnInstance.addPropertyDeletionOverride("KeyName");

    new cdk.CfnOutput(this, "InstanceId", { value: instance.instanceId });
    new cdk.CfnOutput(this, "PrivateIp", { value: instance.instancePrivateIp });
    new cdk.CfnOutput(this, "PublicDns", { value: instance.instancePublicDnsName });
    new cdk.CfnOutput(this, "SSHCommand", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${instance.instancePublicDnsName}` });
    new cdk.CfnOutput(this, "DataFusionBuildLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${instance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
    new cdk.CfnOutput(this, "DataFusionRuntimeLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${instance.instancePublicDnsName} "tail -f ~/datafusion-opensearch-run.log"` });

    // --- Lucene OpenSearch Instance (optional) ---
    let lucenePrivateIp = "";
    if (luceneEnabled) {
      const luceneUserDataScript = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data-lucene.sh"), "utf-8")
        .replace(/\{\{LUCENE_BRANCH\}\}/g, luceneBranch)
        .replace(/\{\{LUCENE_REPO\}\}/g, luceneRepo)
        .replace(/\{\{JVM_HEAP\}\}/g, jvmHeap)
        .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket)
        .replace(/\{\{SCRIPTS_S3_PATH\}\}/g, scriptsS3Path);

      const luceneUserData = ec2.UserData.forLinux();
      luceneUserData.addCommands(luceneUserDataScript);

      const luceneLaunchTemplate = new ec2.LaunchTemplate(this, "LuceneLaunchTemplate", {
        instanceType: new ec2.InstanceType(instanceType),
        machineImage: ec2.MachineImage.latestAmazonLinux2023({ cpuType: ec2.AmazonLinuxCpuType.ARM_64 }),
        securityGroup: sg, instanceProfile, userData: luceneUserData, keyPair,
        blockDevices: [{
          deviceName: "/dev/xvda",
          volume: ec2.BlockDeviceVolume.ebs(ebsSizeGb, {
            volumeType: ec2.EbsDeviceVolumeType.GP3, iops: ebsIops, throughput: ebsThroughput,
          }),
        }],
      });

      const luceneInstance = new ec2.Instance(this, "LuceneInstance", {
        vpc, instanceType: new ec2.InstanceType(instanceType),
        machineImage: ec2.MachineImage.latestAmazonLinux2023({ cpuType: ec2.AmazonLinuxCpuType.ARM_64 }),
        vpcSubnets: { subnets: [subnet] },
      });

      const cfnLuceneInstance = luceneInstance.node.defaultChild as cdk.CfnResource;
      cfnLuceneInstance.addPropertyOverride("LaunchTemplate", { LaunchTemplateId: luceneLaunchTemplate.launchTemplateId, Version: luceneLaunchTemplate.latestVersionNumber });
      cfnLuceneInstance.addPropertyDeletionOverride("SecurityGroupIds");
      cfnLuceneInstance.addPropertyDeletionOverride("UserData");
      cfnLuceneInstance.addPropertyDeletionOverride("IamInstanceProfile");
      cfnLuceneInstance.addPropertyDeletionOverride("KeyName");

      lucenePrivateIp = luceneInstance.instancePrivateIp;

      new cdk.CfnOutput(this, "LuceneInstanceId", { value: luceneInstance.instanceId });
      new cdk.CfnOutput(this, "LucenePrivateIp", { value: luceneInstance.instancePrivateIp });
      new cdk.CfnOutput(this, "LucenePublicDns", { value: luceneInstance.instancePublicDnsName });
      new cdk.CfnOutput(this, "LuceneSSHCommand", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${luceneInstance.instancePublicDnsName}` });
      new cdk.CfnOutput(this, "LuceneBuildLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${luceneInstance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
      new cdk.CfnOutput(this, "LuceneRuntimeLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${luceneInstance.instancePublicDnsName} "tail -f ~/lucene-opensearch-run.log"` });
    }

    // --- Benchmark Instance (optional) ---
    if (benchmarkEnabled) {
      const benchmarkUserDataScript = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data-benchmark.sh"), "utf-8")
        .replace(/\{\{WORKLOAD_REPO\}\}/g, workloadRepo)
        .replace(/\{\{WORKLOAD_BRANCH\}\}/g, workloadBranch)
        .replace(/\{\{DATAFUSION_PRIVATE_IP\}\}/g, instance.instancePrivateIp)
        .replace(/\{\{LUCENE_PRIVATE_IP\}\}/g, lucenePrivateIp)
        .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket)
        .replace(/\{\{SCRIPTS_S3_PATH\}\}/g, scriptsS3Path);

      const benchmarkUserData = ec2.UserData.forLinux();
      benchmarkUserData.addCommands(benchmarkUserDataScript);

      const benchmarkLaunchTemplate = new ec2.LaunchTemplate(this, "BenchmarkLaunchTemplate", {
        instanceType: new ec2.InstanceType(benchmarkInstanceType),
        machineImage: ec2.MachineImage.latestAmazonLinux2023({ cpuType: ec2.AmazonLinuxCpuType.ARM_64 }),
        securityGroup: sg, instanceProfile, userData: benchmarkUserData, keyPair,
        blockDevices: [{
          deviceName: "/dev/xvda",
          volume: ec2.BlockDeviceVolume.ebs(benchmarkEbsSizeGb, { volumeType: ec2.EbsDeviceVolumeType.GP3 }),
        }],
      });

      const benchmarkInstance = new ec2.Instance(this, "BenchmarkInstance", {
        vpc, instanceType: new ec2.InstanceType(benchmarkInstanceType),
        machineImage: ec2.MachineImage.latestAmazonLinux2023({ cpuType: ec2.AmazonLinuxCpuType.ARM_64 }),
        vpcSubnets: { subnets: [subnet] },
      });

      const cfnBenchmarkInstance = benchmarkInstance.node.defaultChild as cdk.CfnResource;
      cfnBenchmarkInstance.addPropertyOverride("LaunchTemplate", { LaunchTemplateId: benchmarkLaunchTemplate.launchTemplateId, Version: benchmarkLaunchTemplate.latestVersionNumber });
      cfnBenchmarkInstance.addPropertyDeletionOverride("SecurityGroupIds");
      cfnBenchmarkInstance.addPropertyDeletionOverride("UserData");
      cfnBenchmarkInstance.addPropertyDeletionOverride("KeyName");
      cfnBenchmarkInstance.addPropertyDeletionOverride("IamInstanceProfile");

      new cdk.CfnOutput(this, "BenchmarkInstanceId", { value: benchmarkInstance.instanceId });
      new cdk.CfnOutput(this, "BenchmarkPublicDns", { value: benchmarkInstance.instancePublicDnsName });
      new cdk.CfnOutput(this, "BenchmarkSSHCommand", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${benchmarkInstance.instancePublicDnsName}` });
      new cdk.CfnOutput(this, "BenchmarkSetupLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${benchmarkInstance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
      new cdk.CfnOutput(this, "BenchmarkRunLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${benchmarkInstance.instancePublicDnsName} "tail -f ~/benchmark-run.log"` });
    }
  }
}
