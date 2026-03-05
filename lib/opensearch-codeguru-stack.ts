import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as codeguruprofiler from "aws-cdk-lib/aws-codeguruprofiler";
import { Construct } from "constructs";

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

    // --- User Data: build OpenSearch + SQL plugin + DataFusion per README ---
    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      "set -exo pipefail",
      "exec > /var/log/user-data.log 2>&1",

      // Install dependencies
      "yum install -y git java-21-amazon-corretto-devel protobuf-compiler protobuf-devel rust cargo cmake",
      "yum groupinstall -y 'Development Tools'",
      "export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto",
      "echo 'export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto' >> /etc/profile.d/java.sh",
      "sysctl -w vm.max_map_count=262144",
      "echo 'vm.max_map_count=262144' >> /etc/sysctl.conf",

      // Step 1: Clone and build OpenSearch — run as ec2-user
      `su -l ec2-user -c 'git clone --branch ${branch} https://github.com/opensearch-project/OpenSearch.git /home/ec2-user/opensearch-src'`,
      "su -l ec2-user -c 'cd /home/ec2-user/opensearch-src && ./gradlew publishToMavenLocal -Dbuild.snapshot=false'",

      // Step 2: Clone and build SQL plugin (substrait-plan branch)
      `su -l ec2-user -c 'git clone --branch ${sqlPluginBranch} ${sqlPluginRepo} /home/ec2-user/sql-plugin'`,
      "su -l ec2-user -c 'cd /home/ec2-user/sql-plugin && ./gradlew publishToMavenLocal -Dbuild.snapshot=false'",
      "su -l ec2-user -c 'cd /home/ec2-user/sql-plugin && ./gradlew :plugin:assemble -Dbuild.snapshot=false'",

      // Step 3: Build engine-datafusion plugin
      "su -l ec2-user -c 'cd /home/ec2-user/opensearch-src && ./gradlew :plugins:engine-datafusion:assemble -Dbuild.snapshot=false'",

      // Step 4: Build local distribution
      "su -l ec2-user -c 'cd /home/ec2-user/opensearch-src && ./gradlew localDistro -Dbuild.snapshot=false'",

      // Step 5: Extract the local distribution
      "su -l ec2-user -c 'mkdir -p /home/ec2-user/opensearch && cp -r /home/ec2-user/opensearch-src/distribution/local/opensearch-*/* /home/ec2-user/opensearch/'",

      // Step 6: Install plugins into the distribution
      "su -l ec2-user -c '/home/ec2-user/opensearch/bin/opensearch-plugin install --batch org.opensearch.plugin:opensearch-job-scheduler:3.3.0.0'",
      "su -l ec2-user -c '/home/ec2-user/opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/sql-plugin/plugin/build/distributions/opensearch-sql-plugin-*.zip'",
      "su -l ec2-user -c '/home/ec2-user/opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/opensearch-src/plugins/engine-datafusion/build/distributions/engine-datafusion-*.zip'",

      // Step 7: Download and configure CodeGuru Profiler agent
      "su -l ec2-user -c 'mkdir -p /home/ec2-user/codeguru'",
      "su -l ec2-user -c 'curl -o /home/ec2-user/codeguru/codeguru-profiler-java-agent-standalone.jar https://d1osg35nybn3tt.cloudfront.net/com/amazonaws/codeguru-profiler-java-agent-standalone/1.2.4/codeguru-profiler-java-agent-standalone-1.2.4.jar'",
      `printf '\\n-javaagent:/home/ec2-user/codeguru/codeguru-profiler-java-agent-standalone.jar="profilingGroupName:opensearch-${safeBranch}-profiling,region:${this.region},heapSummaryEnabled:true"\\n' >> /home/ec2-user/opensearch/config/jvm.options`,
      "chown ec2-user:ec2-user /home/ec2-user/opensearch/config/jvm.options",

      // Step 8: Start OpenSearch as ec2-user
      `cat > /home/ec2-user/run-opensearch.sh << 'SCRIPT'
#!/bin/bash
set -exo pipefail
export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto
/home/ec2-user/opensearch/bin/opensearch
SCRIPT`,
      "chmod +x /home/ec2-user/run-opensearch.sh",
      "chown ec2-user:ec2-user /home/ec2-user/run-opensearch.sh",

      // Start OpenSearch in background
      "su -l ec2-user -c 'nohup /home/ec2-user/run-opensearch.sh > /home/ec2-user/opensearch-run.log 2>&1 &'",
    );

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
