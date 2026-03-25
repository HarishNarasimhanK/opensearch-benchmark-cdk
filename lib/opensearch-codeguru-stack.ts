import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
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
  stackSuffix: string;
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
}

export class OpenSearchCodeGuruStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: OpenSearchCodeGuruStackProps) {
    super(scope, id, props);

    const { branch, opensearchRepo, vpcId, subnetId, subnetAz, securityGroupId, keyPairName, sqlPluginRepo, sqlPluginBranch, stackSuffix, s3ProfileBucket, instanceType, ebsSizeGb, ebsIops, ebsThroughput, jvmHeap, benchmarkEnabled, benchmarkInstanceType, benchmarkEbsSizeGb, workloadRepo, workloadBranch } = props;

    // Sanitize branch name for use in resource names (replace / with -)
    const safeBranch = branch.replace(/\//g, "-");

    // --- Look up existing VPC and Subnet ---
    const vpc = ec2.Vpc.fromLookup(this, "ExistingVpc", { vpcId });
    const subnet = ec2.Subnet.fromSubnetAttributes(this, "ExistingSubnet", {
      subnetId,
      availabilityZone: subnetAz,
    });

    // --- Use existing Security Group ---
    const sg = ec2.SecurityGroup.fromSecurityGroupId(this, "ExistingSG", securityGroupId);

    // --- IAM: create role with S3 and CloudWatch permissions ---
    // Created by CDK so it works in any account — no hardcoded ARNs.
    const role = new iam.Role(this, "OpenSearchInstanceRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonS3FullAccess"),
        iam.ManagedPolicy.fromAwsManagedPolicyName("CloudWatchAgentServerPolicy"),
      ],
    });
    const instanceProfile = new iam.InstanceProfile(this, "OpenSearchInstanceProfile", {
      role,
    });

    // --- Key Pair reference ---
    const keyPair = ec2.KeyPair.fromKeyPairName(this, "ExistingKeyPair", keyPairName);

    // --- User Data: load from scripts/user-data.sh with placeholder substitution ---
    const userDataScript = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data.sh"), "utf-8")
      .replace(/\{\{BRANCH\}\}/g, branch)
      .replace(/\{\{OPENSEARCH_REPO\}\}/g, opensearchRepo)
      .replace(/\{\{SAFE_BRANCH\}\}/g, safeBranch)
      .replace(/\{\{REGION\}\}/g, this.region)
      .replace(/\{\{SQL_PLUGIN_REPO\}\}/g, sqlPluginRepo)
      .replace(/\{\{SQL_PLUGIN_BRANCH\}\}/g, sqlPluginBranch)
      .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket)
      .replace(/\{\{JVM_HEAP\}\}/g, jvmHeap);

    const userData = ec2.UserData.forLinux();
    userData.addCommands(userDataScript);

    // --- Launch Template (needed for EBS throughput support) ---
    const launchTemplate = new ec2.LaunchTemplate(this, "OpenSearchLaunchTemplate", {
      instanceType: new ec2.InstanceType(instanceType),
      machineImage: ec2.MachineImage.latestAmazonLinux2023({
        cpuType: ec2.AmazonLinuxCpuType.ARM_64,
      }),
      securityGroup: sg,
      instanceProfile,
      userData,
      keyPair,
      blockDevices: [
        {
          deviceName: "/dev/xvda",
          volume: ec2.BlockDeviceVolume.ebs(ebsSizeGb, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            iops: ebsIops,
            throughput: ebsThroughput,
          }),
        },
      ],
    });

    // --- EC2 Instance ---
    const instance = new ec2.Instance(this, "OpenSearchInstance", {
      vpc,
      instanceType: new ec2.InstanceType(instanceType),
      machineImage: ec2.MachineImage.latestAmazonLinux2023({
        cpuType: ec2.AmazonLinuxCpuType.ARM_64,
      }),
      vpcSubnets: { subnets: [subnet] },
    });

    // Override the instance to use the launch template via L1 escape hatch
    const cfnInstance = instance.node.defaultChild as cdk.CfnResource;
    cfnInstance.addPropertyOverride("LaunchTemplate", {
      LaunchTemplateId: launchTemplate.launchTemplateId,
      Version: launchTemplate.latestVersionNumber,
    });
    // Remove properties that come from the launch template
    cfnInstance.addPropertyDeletionOverride("SecurityGroupIds");
    cfnInstance.addPropertyDeletionOverride("UserData");
    cfnInstance.addPropertyDeletionOverride("IamInstanceProfile");
    cfnInstance.addPropertyDeletionOverride("KeyName");

    // --- Outputs ---
    new cdk.CfnOutput(this, "InstanceId", { value: instance.instanceId });
    new cdk.CfnOutput(this, "PrivateIp", { value: instance.instancePrivateIp });
    new cdk.CfnOutput(this, "PublicDns", { value: instance.instancePublicDnsName });
    new cdk.CfnOutput(this, "SSHCommand", {
      value: `ssh -i ${keyPairName}.pem ec2-user@${instance.instancePublicDnsName}`,
    });

    // --- Benchmark Instance (optional) ---
    if (benchmarkEnabled) {
      const benchmarkUserDataScript = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data-benchmark.sh"), "utf-8")
        .replace(/\{\{WORKLOAD_REPO\}\}/g, workloadRepo)
        .replace(/\{\{WORKLOAD_BRANCH\}\}/g, workloadBranch)
        .replace(/\{\{OPENSEARCH_PRIVATE_IP\}\}/g, instance.instancePrivateIp)
        .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket);

      const benchmarkUserData = ec2.UserData.forLinux();
      benchmarkUserData.addCommands(benchmarkUserDataScript);

      const benchmarkLaunchTemplate = new ec2.LaunchTemplate(this, "BenchmarkLaunchTemplate", {
        instanceType: new ec2.InstanceType(benchmarkInstanceType),
        machineImage: ec2.MachineImage.latestAmazonLinux2023({
          cpuType: ec2.AmazonLinuxCpuType.ARM_64,
        }),
        securityGroup: sg,
        instanceProfile,
        userData: benchmarkUserData,
        keyPair,
        blockDevices: [
          {
            deviceName: "/dev/xvda",
            volume: ec2.BlockDeviceVolume.ebs(benchmarkEbsSizeGb, {
              volumeType: ec2.EbsDeviceVolumeType.GP3,
            }),
          },
        ],
      });

      const benchmarkInstance = new ec2.Instance(this, "BenchmarkInstance", {
        vpc,
        instanceType: new ec2.InstanceType(benchmarkInstanceType),
        machineImage: ec2.MachineImage.latestAmazonLinux2023({
          cpuType: ec2.AmazonLinuxCpuType.ARM_64,
        }),
        vpcSubnets: { subnets: [subnet] },
      });

      const cfnBenchmarkInstance = benchmarkInstance.node.defaultChild as cdk.CfnResource;
      cfnBenchmarkInstance.addPropertyOverride("LaunchTemplate", {
        LaunchTemplateId: benchmarkLaunchTemplate.launchTemplateId,
        Version: benchmarkLaunchTemplate.latestVersionNumber,
      });
      cfnBenchmarkInstance.addPropertyDeletionOverride("SecurityGroupIds");
      cfnBenchmarkInstance.addPropertyDeletionOverride("UserData");
      cfnBenchmarkInstance.addPropertyDeletionOverride("KeyName");
      cfnBenchmarkInstance.addPropertyDeletionOverride("IamInstanceProfile");

      new cdk.CfnOutput(this, "BenchmarkInstanceId", { value: benchmarkInstance.instanceId });
      new cdk.CfnOutput(this, "BenchmarkPublicDns", { value: benchmarkInstance.instancePublicDnsName });
      new cdk.CfnOutput(this, "BenchmarkSSHCommand", {
        value: `ssh -i ${keyPairName}.pem ec2-user@${benchmarkInstance.instancePublicDnsName}`,
      });
      new cdk.CfnOutput(this, "RunBenchmarkCommand", {
        value: `bash run-benchmark.sh ${instance.instancePrivateIp}`,
      });
    }
  }
}
