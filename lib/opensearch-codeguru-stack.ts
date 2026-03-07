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
}

export class OpenSearchCodeGuruStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: OpenSearchCodeGuruStackProps) {
    super(scope, id, props);

    const { branch, opensearchRepo, vpcId, subnetId, subnetAz, securityGroupId, keyPairName, sqlPluginRepo, sqlPluginBranch, stackSuffix, s3ProfileBucket, instanceType, ebsSizeGb, ebsIops, ebsThroughput, jvmHeap } = props;

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

    // --- IAM: use existing instance profile with S3 and CloudWatch permissions ---
    const instanceProfile = iam.InstanceProfile.fromInstanceProfileAttributes(this, "ExistingInstanceProfile", {
      instanceProfileArn: "arn:aws:iam::619046718411:instance-profile/CloudWatchAgentRole",
      role: iam.Role.fromRoleName(this, "OpenSearchInstanceRole", "CloudWatchAgentRole"),
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
  }
}
