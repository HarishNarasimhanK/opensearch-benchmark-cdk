import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as codeguruprofiler from "aws-cdk-lib/aws-codeguruprofiler";
import { Construct } from "constructs";
import * as fs from "fs";
import * as path from "path";

interface OpenSearchCodeGuruStackProps extends cdk.StackProps {
  branch: string;
  vpcId: string;
  subnetId: string;
  subnetAz: string;
  securityGroupId: string;
  keyPairName: string;
  sqlPluginRepo: string;
  sqlPluginBranch: string;
}

export class OpenSearchCodeGuruStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: OpenSearchCodeGuruStackProps) {
    super(scope, id, props);

    const { branch, vpcId, subnetId, subnetAz, securityGroupId, keyPairName, sqlPluginRepo, sqlPluginBranch } = props;

    // Sanitize branch name for use in resource names (replace / with -)
    const safeBranch = branch.replace(/\//g, "-");

    // --- CodeGuru Profiling Group ---
    const profilingGroup = new codeguruprofiler.CfnProfilingGroup(this, "OpenSearchProfilingGroup", {
      profilingGroupName: `opensearch-${safeBranch}-profiling`,
      computePlatform: "Default",
    });

    // --- Look up existing VPC and Subnet ---
    const vpc = ec2.Vpc.fromLookup(this, "ExistingVpc", { vpcId });
    const subnet = ec2.Subnet.fromSubnetAttributes(this, "ExistingSubnet", {
      subnetId,
      availabilityZone: subnetAz,
    });

    // --- Use existing Security Group ---
    const sg = ec2.SecurityGroup.fromSecurityGroupId(this, "ExistingSG", securityGroupId);

    // --- IAM Role for EC2 ---
    const role = new iam.Role(this, "OpenSearchInstanceRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore"),
      ],
    });

    role.addToPolicy(new iam.PolicyStatement({
      actions: [
        "codeguru-profiler:ConfigureAgent",
        "codeguru-profiler:PostAgentProfile",
      ],
      resources: [
        `arn:aws:codeguru-profiler:${this.region}:${this.account}:profilingGroup/opensearch-${safeBranch}-profiling`,
      ],
    }));

    // --- Key Pair reference ---
    const keyPair = ec2.KeyPair.fromKeyPairName(this, "ExistingKeyPair", keyPairName);

    // --- User Data: load from scripts/user-data.sh with placeholder substitution ---
    const userDataScript = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data.sh"), "utf-8")
      .replace(/\{\{BRANCH\}\}/g, branch)
      .replace(/\{\{SAFE_BRANCH\}\}/g, safeBranch)
      .replace(/\{\{REGION\}\}/g, this.region)
      .replace(/\{\{SQL_PLUGIN_REPO\}\}/g, sqlPluginRepo)
      .replace(/\{\{SQL_PLUGIN_BRANCH\}\}/g, sqlPluginBranch);

    const userData = ec2.UserData.forLinux();
    userData.addCommands(userDataScript);

    // --- EC2 Instance ---
    const instance = new ec2.Instance(this, "OpenSearchInstance", {
      vpc,
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.M5, ec2.InstanceSize.XLARGE2),
      machineImage: ec2.MachineImage.latestAmazonLinux2023(),
      securityGroup: sg,
      role,
      userData,
      keyPair,
      blockDevices: [
        {
          deviceName: "/dev/xvda",
          volume: ec2.BlockDeviceVolume.ebs(100, { volumeType: ec2.EbsDeviceVolumeType.GP3 }),
        },
      ],
      vpcSubnets: { subnets: [subnet] },
    });

    // --- Outputs ---
    new cdk.CfnOutput(this, "InstanceId", { value: instance.instanceId });
    new cdk.CfnOutput(this, "PrivateIp", { value: instance.instancePrivateIp });
    new cdk.CfnOutput(this, "ProfilingGroupName", { value: `opensearch-${safeBranch}-profiling` });
    new cdk.CfnOutput(this, "SSHCommand", {
      value: `ssh -i ${keyPairName}.pem ec2-user@<instance-ip>`,
    });
    new cdk.CfnOutput(this, "ProfilingGroupConsoleUrl", {
      value: `https://${this.region}.console.aws.amazon.com/codeguru/profiler/profile?profilingGroupName=opensearch-${safeBranch}-profiling`,
    });
  }
}
