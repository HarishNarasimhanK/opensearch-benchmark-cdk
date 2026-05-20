import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as elbv2 from "aws-cdk-lib/aws-elasticloadbalancingv2";
import * as targets from "aws-cdk-lib/aws-elasticloadbalancingv2-targets";
import * as s3assets from "aws-cdk-lib/aws-s3-assets";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as cw from "aws-cdk-lib/aws-cloudwatch";
import { Construct } from "constructs";
import * as fs from "fs";
import * as path from "path";

interface OpenSearchCodeGuruStackProps extends cdk.StackProps {
  // Parquet engine
  parquetRepo: string;
  parquetBranch: string;
  parquetInstanceType: string;
  parquetEbsSizeGb: number;
  parquetEbsIops: number;
  parquetEbsThroughput: number;
  parquetJvmHeap: string;
  parquetWorkloadRepo: string;
  parquetWorkloadBranch: string;

  // Lucene engine
  luceneEnabled: boolean;
  luceneRepo: string;
  luceneBranch: string;
  luceneInstanceType: string;
  luceneEbsSizeGb: number;
  luceneEbsIops: number;
  luceneEbsThroughput: number;
  luceneJvmHeap: string;
  luceneWorkloadRepo: string;
  luceneWorkloadBranch: string;

  // ParquetLucene engine
  parquetLuceneEnabled: boolean;
  parquetLuceneInstanceType: string;
  parquetLuceneEbsSizeGb: number;
  parquetLuceneEbsIops: number;
  parquetLuceneEbsThroughput: number;
  parquetLuceneJvmHeap: string;
  parquetLuceneWorkloadRepo: string;
  parquetLuceneWorkloadBranch: string;

  // Benchmark instance
  benchmarkEnabled: boolean;
  benchmarkInstanceType: string;
  benchmarkEbsSizeGb: number;
  benchmarkEbsIops: number;
  benchmarkEbsThroughput: number;
  testIterations: number;
  ingestPercentage: number;

  // Networking
  vpcId: string;
  subnetId: string;
  subnetAz: string;
  securityGroupId: string;
  keyPairName: string;
  s3ProfileBucket: string;

  // Cluster
  clusterMode: string;
  dataNodeCount: number;
  remoteStoreEnabled: boolean;

  // Metrics
  metricsStoreHost: string;
  metricsStorePort: string;
  metricsStoreSecure: string;

  // Run
  runId: string;
  runIdPrefix: string;
}

export class OpenSearchCodeGuruStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: OpenSearchCodeGuruStackProps) {
    super(scope, id, props);

    const { vpcId, subnetId, subnetAz, securityGroupId, keyPairName, s3ProfileBucket,
      parquetRepo, parquetBranch, parquetInstanceType, parquetEbsSizeGb, parquetEbsIops, parquetEbsThroughput, parquetJvmHeap,
      parquetWorkloadRepo, parquetWorkloadBranch,
      luceneEnabled, luceneRepo, luceneBranch, luceneInstanceType, luceneEbsSizeGb, luceneEbsIops, luceneEbsThroughput, luceneJvmHeap,
      luceneWorkloadRepo, luceneWorkloadBranch,
      parquetLuceneEnabled, parquetLuceneInstanceType, parquetLuceneEbsSizeGb, parquetLuceneEbsIops, parquetLuceneEbsThroughput, parquetLuceneJvmHeap,
      parquetLuceneWorkloadRepo, parquetLuceneWorkloadBranch,
      benchmarkEnabled, benchmarkInstanceType, benchmarkEbsSizeGb, benchmarkEbsIops, benchmarkEbsThroughput,
      testIterations, ingestPercentage,
      clusterMode, dataNodeCount, remoteStoreEnabled, metricsStoreHost, metricsStorePort, metricsStoreSecure, runId, runIdPrefix } = props;

    const isMultiNode = clusterMode === "multi";
    const clusterTag = `${id}-parquet-cluster`;
    // Log group prefix: "/opensearch" for normal, "/opensearch/nightly" for nightly
    const logGroupPrefix = runIdPrefix ? `/opensearch/${runIdPrefix}` : "/opensearch";

    // --- Remote Store S3 bucket (created only when enabled) ---
    let remoteStoreBucketName = "";
    if (remoteStoreEnabled) {
      const remoteStoreBucket = new s3.Bucket(this, "RemoteStoreBucket", {
        removalPolicy: cdk.RemovalPolicy.DESTROY,
        autoDeleteObjects: true,
        encryption: s3.BucketEncryption.S3_MANAGED,
        lifecycleRules: [{ expiration: cdk.Duration.days(30) }],
      });
      remoteStoreBucketName = remoteStoreBucket.bucketName;
    }

    // --- Look up existing VPC and Subnet ---
    const vpc = ec2.Vpc.fromLookup(this, "ExistingVpc", { vpcId });
    const subnet = ec2.Subnet.fromSubnetAttributes(this, "ExistingSubnet", {
      subnetId, availabilityZone: subnetAz,
    });
    const sg = ec2.SecurityGroup.fromSecurityGroupId(this, "ExistingSG", securityGroupId, {
      mutable: false, // Prevent CDK from adding ingress rules (e.g., ALB health check 0.0.0.0/0 on 9200)
    });

    // --- IAM role ---
    const managedPolicies = [
      iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonS3FullAccess"),
      iam.ManagedPolicy.fromAwsManagedPolicyName("CloudWatchAgentServerPolicy"),
    ];
    if (isMultiNode) {
      managedPolicies.push(iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonEC2ReadOnlyAccess"));
    }
    const role = new iam.Role(this, "OpenSearchInstanceRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      managedPolicies,
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

      const lt = new ec2.LaunchTemplate(this, ltId, {
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
      });

      const inst = new ec2.Instance(this, nodeId, {
        vpc, instanceType: new ec2.InstanceType(instType),
        machineImage: ec2.MachineImage.latestAmazonLinux2023({ cpuType: ec2.AmazonLinuxCpuType.ARM_64 }),
        vpcSubnets: { subnets: [subnet] },
        securityGroup: sg, // Use the imported SG — prevents CDK from creating orphan SGs
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

    // --- Helper: create a Parquet instance with cluster config ---
    const createParquetInstance = (nodeId: string, ltId: string, nodeName: string, nodeRoles: string): ec2.Instance => {
      const script = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data-parquet.sh"), "utf-8")
        .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket)
        .replace(/\{\{JVM_HEAP\}\}/g, parquetJvmHeap)
        .replace(/\{\{SCRIPTS_S3_PATH\}\}/g, scriptsS3Path)
        .replace(/\{\{CLUSTER_MODE\}\}/g, clusterMode)
        .replace(/\{\{CLUSTER_TAG\}\}/g, clusterTag)
        .replace(/\{\{NODE_NAME\}\}/g, nodeName)
        .replace(/\{\{NODE_ROLES\}\}/g, nodeRoles)
        .replace(/\{\{BENCHMARK_ENABLED\}\}/g, String(benchmarkEnabled))
        .replace(/\{\{RUN_ID\}\}/g, runId)
        .replace(/\{\{LOG_GROUP_PREFIX\}\}/g, logGroupPrefix)
        .replace(/\{\{REMOTE_STORE_ENABLED\}\}/g, String(remoteStoreEnabled))
        .replace(/\{\{REMOTE_STORE_BUCKET\}\}/g, remoteStoreBucketName)
        .replace(/\{\{AWS_REGION\}\}/g, this.region);

      const inst = createInstance(nodeId, ltId, script, parquetInstanceType, parquetEbsSizeGb, parquetEbsIops, parquetEbsThroughput);
      const nameTag = nodeName ? `${id}-Parquet-${runId}-${nodeName}` : `${id}-Parquet-${runId}`;
      cdk.Tags.of(inst).add("Name", nameTag);

      if (isMultiNode) {
        cdk.Tags.of(inst).add("cluster", clusterTag);
      }

      return inst;
    };

    // =========================================================================
    // Builder Instance — builds both Parquet and Lucene, uploads tar.gz to S3
    // =========================================================================
    const builderScript = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data-builder.sh"), "utf-8")
      .replace(/\{\{PARQUET_BRANCH\}\}/g, parquetBranch)
      .replace(/\{\{PARQUET_REPO\}\}/g, parquetRepo)
      .replace(/\{\{LUCENE_BRANCH\}\}/g, luceneBranch)
      .replace(/\{\{LUCENE_REPO\}\}/g, luceneRepo)
      .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket)
      .replace(/\{\{RUN_ID\}\}/g, runId)
      .replace(/\{\{LOG_GROUP_PREFIX\}\}/g, logGroupPrefix)
      .replace(/\{\{REMOTE_STORE_ENABLED\}\}/g, String(remoteStoreEnabled));

    const builderInstance = createInstance("BuilderInstance", "BuilderLt", builderScript, parquetInstanceType, parquetEbsSizeGb, parquetEbsIops, parquetEbsThroughput);
    cdk.Tags.of(builderInstance).add("Name", `${id}-Builder-${runId}`);

    new cdk.CfnOutput(this, "BuilderSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${builderInstance.instancePublicDnsName}` });
    new cdk.CfnOutput(this, "BuilderLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${builderInstance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });

    // =========================================================================
    // Parquet OpenSearch: single-node or multi-node cluster
    // =========================================================================
    let parquetEndpoint: string;
    let parquetInstanceId: string = "";

    if (isMultiNode) {
      // --- Multi-node: 3 managers + N data nodes + internal ALB ---
      const seedManager = createParquetInstance("SeedManager", "SeedManagerLt", "clusterManager-seed", "cluster_manager");
      new cdk.CfnOutput(this, "SeedManagerSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${seedManager.instancePublicDnsName}` });

      for (let i = 2; i <= 3; i++) {
        createParquetInstance(`Manager${i}`, `Manager${i}Lt`, `clusterManager-${i}`, "cluster_manager");
      }

      const dataInstances: ec2.Instance[] = [];
      for (let i = 1; i <= dataNodeCount; i++) {
        const data = createParquetInstance(`DataNode${i}`, `DataNode${i}Lt`, `dataNode-${i}`, "data, ingest");
        dataInstances.push(data);
        if (i === 1) parquetInstanceId = data.instanceId;  // Use first data node for CloudWatch dashboard
        new cdk.CfnOutput(this, `ParquetDataNode${i}SSH`, { value: `ssh -i ~/${keyPairName}.pem ec2-user@${data.instancePublicDnsName}` });
      }

      // Internal ALB — routes to data nodes on port 9200
      const alb = new elbv2.ApplicationLoadBalancer(this, "ClusterALB", {
        vpc, internetFacing: false, securityGroup: sg,
      });

      const listener = alb.addListener("OpenSearchListener", {
        port: 9200, protocol: elbv2.ApplicationProtocol.HTTP,
      });

      listener.addTargets("DataNodeTargets", {
        port: 9200,
        protocol: elbv2.ApplicationProtocol.HTTP,
        targets: dataInstances.map((inst) => new targets.InstanceTarget(inst, 9200)),
        healthCheck: {
          path: "/", port: "9200", healthyHttpCodes: "200",
          interval: cdk.Duration.seconds(30), timeout: cdk.Duration.seconds(10),
          healthyThresholdCount: 2, unhealthyThresholdCount: 10,
        },
      });

      parquetEndpoint = alb.loadBalancerDnsName;

      new cdk.CfnOutput(this, "ParquetClusterALBUrl", { value: `http://${alb.loadBalancerDnsName}:9200` });
      new cdk.CfnOutput(this, "ParquetClusterMode", { value: `multi (3 managers + ${dataNodeCount} data nodes)` });

    } else {
      // --- Single-node (default) ---
      const instance = createParquetInstance("ParquetInstance", "ParquetLt", "node", "");
      parquetEndpoint = instance.instancePrivateIp;
      parquetInstanceId = instance.instanceId;

      new cdk.CfnOutput(this, "ParquetSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${instance.instancePublicDnsName}` });
      new cdk.CfnOutput(this, "ParquetSetupLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${instance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
      new cdk.CfnOutput(this, "ParquetRuntimeLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${instance.instancePublicDnsName} "tail -f ~/parquet-opensearch-run.log"` });
      new cdk.CfnOutput(this, "ParquetPrivateIp", { value: instance.instancePrivateIp });
    }

    // =========================================================================
    // Lucene OpenSearch: single-node or multi-node cluster
    // =========================================================================
    let luceneEndpoint = "";
    let luceneInstanceId: string = "";
    if (luceneEnabled) {
      const luceneClusterTag = `${id}-lucene-cluster`;

      // Helper: create a Lucene instance with cluster config
      const createLuceneInstance = (nodeId: string, ltId: string, nodeName: string, nodeRoles: string): ec2.Instance => {
        const script = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data-lucene.sh"), "utf-8")
          .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket)
          .replace(/\{\{JVM_HEAP\}\}/g, luceneJvmHeap)
          .replace(/\{\{SCRIPTS_S3_PATH\}\}/g, scriptsS3Path)
          .replace(/\{\{CLUSTER_MODE\}\}/g, clusterMode)
          .replace(/\{\{CLUSTER_TAG\}\}/g, luceneClusterTag)
          .replace(/\{\{NODE_NAME\}\}/g, nodeName)
          .replace(/\{\{NODE_ROLES\}\}/g, nodeRoles)
          .replace(/\{\{BENCHMARK_ENABLED\}\}/g, String(benchmarkEnabled))
          .replace(/\{\{RUN_ID\}\}/g, runId)
          .replace(/\{\{LOG_GROUP_PREFIX\}\}/g, logGroupPrefix)
          .replace(/\{\{REMOTE_STORE_ENABLED\}\}/g, String(remoteStoreEnabled))
          .replace(/\{\{REMOTE_STORE_BUCKET\}\}/g, remoteStoreBucketName)
          .replace(/\{\{AWS_REGION\}\}/g, this.region);

        const inst = createInstance(nodeId, ltId, script, luceneInstanceType, luceneEbsSizeGb, luceneEbsIops, luceneEbsThroughput);
        const nameTag = nodeName ? `${id}-Lucene-${runId}-${nodeName}` : `${id}-Lucene-${runId}`;
        cdk.Tags.of(inst).add("Name", nameTag);

        if (isMultiNode) {
          cdk.Tags.of(inst).add("cluster", luceneClusterTag);
        }

        return inst;
      };

      if (isMultiNode) {
        // --- Multi-node: 3 managers + N data nodes + internal ALB ---
        const luceneSeedManager = createLuceneInstance("LuceneSeedManager", "LuceneSeedManagerLt", "clusterManager-seed", "cluster_manager");
        new cdk.CfnOutput(this, "LuceneSeedManagerSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${luceneSeedManager.instancePublicDnsName}` });

        for (let i = 2; i <= 3; i++) {
          createLuceneInstance(`LuceneManager${i}`, `LuceneManager${i}Lt`, `clusterManager-${i}`, "cluster_manager");
        }

        const luceneDataInstances: ec2.Instance[] = [];
        for (let i = 1; i <= dataNodeCount; i++) {
          const data = createLuceneInstance(`LuceneDataNode${i}`, `LuceneDataNode${i}Lt`, `dataNode-${i}`, "data, ingest");
          luceneDataInstances.push(data);
          if (i === 1) luceneInstanceId = data.instanceId;  // Use first data node for CloudWatch dashboard
          new cdk.CfnOutput(this, `LuceneDataNode${i}SSH`, { value: `ssh -i ~/${keyPairName}.pem ec2-user@${data.instancePublicDnsName}` });
        }

        // Internal ALB for Lucene cluster
        const luceneAlb = new elbv2.ApplicationLoadBalancer(this, "LuceneClusterALB", {
          vpc, internetFacing: false, securityGroup: sg,
        });

        const luceneListener = luceneAlb.addListener("LuceneOpenSearchListener", {
          port: 9200, protocol: elbv2.ApplicationProtocol.HTTP,
        });

        luceneListener.addTargets("LuceneDataNodeTargets", {
          port: 9200,
          protocol: elbv2.ApplicationProtocol.HTTP,
          targets: luceneDataInstances.map((inst) => new targets.InstanceTarget(inst, 9200)),
          healthCheck: {
            path: "/", port: "9200", healthyHttpCodes: "200",
            interval: cdk.Duration.seconds(30), timeout: cdk.Duration.seconds(10),
            healthyThresholdCount: 2, unhealthyThresholdCount: 10,
          },
        });

        luceneEndpoint = luceneAlb.loadBalancerDnsName;

        new cdk.CfnOutput(this, "LuceneClusterALBUrl", { value: `http://${luceneAlb.loadBalancerDnsName}:9200` });
        new cdk.CfnOutput(this, "LuceneClusterMode", { value: `multi (3 managers + ${dataNodeCount} data nodes)` });

      } else {
        // --- Single-node (default) ---
        const luceneInstance = createLuceneInstance("LuceneInstance", "LuceneLt", "node", "");
        luceneEndpoint = luceneInstance.instancePrivateIp;
        luceneInstanceId = luceneInstance.instanceId;

        new cdk.CfnOutput(this, "LuceneSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${luceneInstance.instancePublicDnsName}` });
        new cdk.CfnOutput(this, "LuceneSetupLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${luceneInstance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
        new cdk.CfnOutput(this, "LucenePrivateIp", { value: luceneInstance.instancePrivateIp });
      }
    }

    // =========================================================================
    // ParquetLucene OpenSearch: same binary as Parquet, different workload (indexed_parquet)
    // =========================================================================
    let parquetLuceneEndpoint = "";
    let parquetLuceneInstanceId: string = "";
    if (parquetLuceneEnabled) {
      const parquetLuceneClusterTag = `${id}-parquetLucene-cluster`;

      const createParquetLuceneInstance = (nodeId: string, ltId: string, nodeName: string, nodeRoles: string): ec2.Instance => {
        const script = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data-parquetLucene.sh"), "utf-8")
          .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket)
          .replace(/\{\{JVM_HEAP\}\}/g, parquetLuceneJvmHeap)
          .replace(/\{\{SCRIPTS_S3_PATH\}\}/g, scriptsS3Path)
          .replace(/\{\{CLUSTER_MODE\}\}/g, clusterMode)
          .replace(/\{\{CLUSTER_TAG\}\}/g, parquetLuceneClusterTag)
          .replace(/\{\{NODE_NAME\}\}/g, nodeName)
          .replace(/\{\{NODE_ROLES\}\}/g, nodeRoles)
          .replace(/\{\{BENCHMARK_ENABLED\}\}/g, String(benchmarkEnabled))
          .replace(/\{\{RUN_ID\}\}/g, runId)
          .replace(/\{\{LOG_GROUP_PREFIX\}\}/g, logGroupPrefix)
          .replace(/\{\{REMOTE_STORE_ENABLED\}\}/g, String(remoteStoreEnabled))
          .replace(/\{\{REMOTE_STORE_BUCKET\}\}/g, remoteStoreBucketName)
          .replace(/\{\{AWS_REGION\}\}/g, this.region);

        const inst = createInstance(nodeId, ltId, script, parquetLuceneInstanceType, parquetLuceneEbsSizeGb, parquetLuceneEbsIops, parquetLuceneEbsThroughput);
        cdk.Tags.of(inst).add("Name", `${id}-ParquetLucene-${runId}-${nodeName}`);

        if (isMultiNode) {
          cdk.Tags.of(inst).add("cluster", parquetLuceneClusterTag);
        }

        return inst;
      };

      if (isMultiNode) {
        // --- Multi-node: 3 managers + N data nodes + internal ALB ---
        const pqlSeedManager = createParquetLuceneInstance("PQLSeedManager", "PQLSeedManagerLt", "clusterManager-seed", "cluster_manager");
        new cdk.CfnOutput(this, "ParquetLuceneSeedManagerSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${pqlSeedManager.instancePublicDnsName}` });

        for (let i = 2; i <= 3; i++) {
          createParquetLuceneInstance(`PQLManager${i}`, `PQLManager${i}Lt`, `clusterManager-${i}`, "cluster_manager");
        }

        const pqlDataInstances: ec2.Instance[] = [];
        for (let i = 1; i <= dataNodeCount; i++) {
          const data = createParquetLuceneInstance(`PQLDataNode${i}`, `PQLDataNode${i}Lt`, `dataNode-${i}`, "data, ingest");
          pqlDataInstances.push(data);
          if (i === 1) parquetLuceneInstanceId = data.instanceId;
          new cdk.CfnOutput(this, `ParquetLuceneDataNode${i}SSH`, { value: `ssh -i ~/${keyPairName}.pem ec2-user@${data.instancePublicDnsName}` });
        }

        // Internal ALB for ParquetLucene cluster
        const pqlAlb = new elbv2.ApplicationLoadBalancer(this, "PQLClusterALB", {
          vpc, internetFacing: false, securityGroup: sg,
        });

        const pqlListener = pqlAlb.addListener("PQLOpenSearchListener", {
          port: 9200, protocol: elbv2.ApplicationProtocol.HTTP,
        });

        pqlListener.addTargets("PQLDataNodeTargets", {
          port: 9200,
          protocol: elbv2.ApplicationProtocol.HTTP,
          targets: pqlDataInstances.map((inst) => new targets.InstanceTarget(inst, 9200)),
          healthCheck: {
            path: "/", port: "9200", healthyHttpCodes: "200",
            interval: cdk.Duration.seconds(30), timeout: cdk.Duration.seconds(10),
            healthyThresholdCount: 2, unhealthyThresholdCount: 10,
          },
        });

        parquetLuceneEndpoint = pqlAlb.loadBalancerDnsName;

        new cdk.CfnOutput(this, "ParquetLuceneClusterALBUrl", { value: `http://${pqlAlb.loadBalancerDnsName}:9200` });
        new cdk.CfnOutput(this, "ParquetLuceneClusterMode", { value: `multi (3 managers + ${dataNodeCount} data nodes)` });

      } else {
        // --- Single-node (default) ---
        const parquetLuceneInstance = createParquetLuceneInstance("ParquetLuceneInstance", "ParquetLuceneLt", "node", "");
        parquetLuceneEndpoint = parquetLuceneInstance.instancePrivateIp;
        parquetLuceneInstanceId = parquetLuceneInstance.instanceId;

        new cdk.CfnOutput(this, "ParquetLuceneSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${parquetLuceneInstance.instancePublicDnsName}` });
        new cdk.CfnOutput(this, "ParquetLuceneSetupLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${parquetLuceneInstance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
        new cdk.CfnOutput(this, "ParquetLuceneRuntimeLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${parquetLuceneInstance.instancePublicDnsName} "tail -f ~/parquetLucene-opensearch-run.log"` });
        new cdk.CfnOutput(this, "ParquetLucenePrivateIp", { value: parquetLuceneInstance.instancePrivateIp });
      }
    }

    // =========================================================================
    // Benchmark Instance (optional) — runs OSB + correctness tests
    // =========================================================================
    if (benchmarkEnabled) {
      const benchmarkScript = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data-benchmark.sh"), "utf-8")
        .replace(/\{\{PARQUET_WORKLOAD_REPO\}\}/g, parquetWorkloadRepo)
        .replace(/\{\{PARQUET_WORKLOAD_BRANCH\}\}/g, parquetWorkloadBranch)
        .replace(/\{\{LUCENE_WORKLOAD_REPO\}\}/g, luceneWorkloadRepo)
        .replace(/\{\{LUCENE_WORKLOAD_BRANCH\}\}/g, luceneWorkloadBranch)
        .replace(/\{\{PARQUET_LUCENE_WORKLOAD_REPO\}\}/g, parquetLuceneWorkloadRepo)
        .replace(/\{\{PARQUET_LUCENE_WORKLOAD_BRANCH\}\}/g, parquetLuceneWorkloadBranch)
        .replace(/\{\{PARQUET_PRIVATE_IP\}\}/g, parquetEndpoint)
        .replace(/\{\{LUCENE_PRIVATE_IP\}\}/g, luceneEndpoint)
        .replace(/\{\{PARQUET_LUCENE_PRIVATE_IP\}\}/g, parquetLuceneEndpoint)
        .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket)
        .replace(/\{\{SCRIPTS_S3_PATH\}\}/g, scriptsS3Path)
        .replace(/\{\{DATA_NODE_COUNT\}\}/g, String(isMultiNode ? dataNodeCount : 1))
        .replace(/\{\{METRICS_STORE_HOST\}\}/g, metricsStoreHost)
        .replace(/\{\{METRICS_STORE_PORT\}\}/g, metricsStorePort)
        .replace(/\{\{METRICS_STORE_SECURE\}\}/g, metricsStoreSecure)
        .replace(/\{\{TEST_ITERATIONS\}\}/g, String(testIterations))
        .replace(/\{\{INGEST_PERCENTAGE\}\}/g, String(ingestPercentage))
        .replace(/\{\{RUN_ID\}\}/g, runId)
        .replace(/\{\{LOG_GROUP_PREFIX\}\}/g, logGroupPrefix);

      const benchmarkInstance = createInstance("BenchmarkInstance", "BenchmarkLt", benchmarkScript, benchmarkInstanceType, benchmarkEbsSizeGb, benchmarkEbsIops, benchmarkEbsThroughput);
      cdk.Tags.of(benchmarkInstance).add("Name", `${id}-Benchmark-${runId}`);

      new cdk.CfnOutput(this, "BenchmarkSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${benchmarkInstance.instancePublicDnsName}` });
      new cdk.CfnOutput(this, "BenchmarkSetupLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${benchmarkInstance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
      new cdk.CfnOutput(this, "BenchmarkRunLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${benchmarkInstance.instancePublicDnsName} "tail -f ~/benchmark-run.log"` });
    }

    // =========================================================================
    // Metrics Store
    // =========================================================================
    if (metricsStoreHost && benchmarkEnabled) {
      new cdk.CfnOutput(this, "MetricsStoreEndpoint", { value: `https://${metricsStoreHost}` });
      new cdk.CfnOutput(this, "MetricsStoreDashboard", { value: `https://${metricsStoreHost}/_dashboards (access via SSH tunnel: ssh -i ~/${keyPairName}.pem -L 5601:${metricsStoreHost}:443 ec2-user@<benchmark-dns> then open https://localhost:5601/_dashboards)` });
    }

    // =========================================================================
    // CloudWatch Dashboard — All 3 engines: system metrics + node-stats
    // =========================================================================
    const metricsNamespace = `OpenSearch/${runId}`;
    const pqInstanceId = parquetInstanceId;
    const luInstanceId = luceneInstanceId;
    const pqlInstanceId = parquetLuceneInstanceId;

    // Helper: create a metric for a given instance
    const cwMetric = (metricName: string, instanceId: string, extraDims?: Record<string, string>): cw.Metric =>
      new cw.Metric({
        namespace: metricsNamespace, metricName,
        dimensionsMap: { InstanceId: instanceId, ...extraDims },
        period: cdk.Duration.seconds(60), statistic: "Average",
      });

    // Helper: 3-engine graph (all on left axis for direct comparison)
    const tripleGraph = (title: string, metricName: string, yLabel: string, extraDims?: Record<string, string>): cw.GraphWidget => {
      const metrics: cw.Metric[] = [];
      if (pqInstanceId) metrics.push(cwMetric(metricName, pqInstanceId, extraDims).with({ label: "Parquet", color: "#FF6B35" }));
      if (luInstanceId) metrics.push(cwMetric(metricName, luInstanceId, extraDims).with({ label: "Lucene", color: "#004E89" }));
      if (pqlInstanceId) metrics.push(cwMetric(metricName, pqlInstanceId, extraDims).with({ label: "ParquetLucene", color: "#7B2D8B" }));
      return new cw.GraphWidget({
        title, width: 12, height: 6, left: metrics,
        leftYAxis: { label: yLabel },
      });
    };

    const dashboard = new cw.Dashboard(this, "BenchmarkDashboard", {
      dashboardName: `OpenSearch-${runId}`,
    });

    // --- Header ---
    dashboard.addWidgets(
      new cw.TextWidget({
        markdown: `# Benchmark Dashboard — ${runId}\nEngines: Parquet | Lucene | ParquetLucene\nNamespace: \`${metricsNamespace}\`\n\nGraphs populate ~30-40 min after deploy (after build + OpenSearch start).`,
        width: 24, height: 2,
      }),
    );

    // --- CPU ---
    dashboard.addWidgets(
      tripleGraph("CPU — User (%)", "cpu_usage_user", "%"),
      tripleGraph("CPU — System (%)", "cpu_usage_system", "%"),
    );
    dashboard.addWidgets(
      tripleGraph("CPU — IOWait (%)", "cpu_usage_iowait", "%"),
      tripleGraph("CPU — Idle (%)", "cpu_usage_idle", "%"),
    );

    // --- Memory ---
    dashboard.addWidgets(
      tripleGraph("Memory Used (%)", "mem_used_percent", "%"),
      tripleGraph("Memory Available (bytes)", "mem_available", "bytes"),
    );

    // --- Disk I/O ---
    dashboard.addWidgets(
      tripleGraph("Disk — Write Bytes/s", "diskio_write_bytes", "bytes"),
      tripleGraph("Disk — Read Bytes/s", "diskio_read_bytes", "bytes"),
    );
    dashboard.addWidgets(
      tripleGraph("Disk — IOPS In Progress", "diskio_iops_in_progress", "count"),
      tripleGraph("Disk — Used (%)", "disk_used_percent", "%"),
    );

    // --- Network ---
    dashboard.addWidgets(
      tripleGraph("Network — Bytes Sent", "net_bytes_sent", "bytes"),
      tripleGraph("Network — Bytes Received", "net_bytes_recv", "bytes"),
    );

    // --- Swap ---
    dashboard.addWidgets(
      tripleGraph("Swap Used (%)", "swap_used_percent", "%"),
      tripleGraph("TCP Connections — Established", "netstat_tcp_established", "count"),
    );

    // --- vmstat (from logs) ---
    const vmstatWidget = (title: string, logGroup: string, field: string): cw.LogQueryWidget =>
      new cw.LogQueryWidget({
        title, logGroupNames: [logGroup],
        queryLines: [
          `fields @timestamp, @message`,
          `parse @message "* free:* buff:* cache:*" as ts, free, buff, cache`,
          `stats avg(${field}) as ${field}_kb by bin(1m)`,
        ],
        view: cw.LogQueryVisualizationType.LINE,
        width: 8, height: 6,
      });

    dashboard.addWidgets(
      vmstatWidget("Parquet — Free Mem (KB)", `${logGroupPrefix}/parquet/vmstat`, "free"),
      vmstatWidget("Lucene — Free Mem (KB)", `${logGroupPrefix}/lucene/vmstat`, "free"),
      vmstatWidget("ParquetLucene — Free Mem (KB)", `${logGroupPrefix}/parquetLucene/vmstat`, "free"),
    );
    dashboard.addWidgets(
      vmstatWidget("Parquet — Buffer (KB)", `${logGroupPrefix}/parquet/vmstat`, "buff"),
      vmstatWidget("Lucene — Buffer (KB)", `${logGroupPrefix}/lucene/vmstat`, "buff"),
      vmstatWidget("ParquetLucene — Buffer (KB)", `${logGroupPrefix}/parquetLucene/vmstat`, "buff"),
    );
    dashboard.addWidgets(
      vmstatWidget("Parquet — Cache (KB)", `${logGroupPrefix}/parquet/vmstat`, "cache"),
      vmstatWidget("Lucene — Cache (KB)", `${logGroupPrefix}/lucene/vmstat`, "cache"),
      vmstatWidget("ParquetLucene — Cache (KB)", `${logGroupPrefix}/parquetLucene/vmstat`, "cache"),
    );

    // --- Node Stats (from logs) — JVM heap, merges, indexing, queries ---
    const nodeStatsWidget = (title: string, logGroup: string, queryLines: string[]): cw.LogQueryWidget =>
      new cw.LogQueryWidget({
        title, logGroupNames: [logGroup],
        queryLines,
        view: cw.LogQueryVisualizationType.LINE,
        width: 8, height: 6,
      });

    // JVM Heap Used %
    dashboard.addWidgets(
      new cw.TextWidget({ markdown: "## Node Stats (from `_nodes/stats` every 10s)", width: 24, height: 1 }),
    );
    dashboard.addWidgets(
      nodeStatsWidget("Parquet — JVM Heap Used %", `${logGroupPrefix}/parquet/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"heap_used_percent":(?<heap_pct>\\d+)/ `,
        `filter ispresent(heap_pct)`,
        `stats avg(heap_pct) as heap_percent by bin(1m)`,
      ]),
      nodeStatsWidget("Lucene — JVM Heap Used %", `${logGroupPrefix}/lucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"heap_used_percent":(?<heap_pct>\\d+)/ `,
        `filter ispresent(heap_pct)`,
        `stats avg(heap_pct) as heap_percent by bin(1m)`,
      ]),
      nodeStatsWidget("ParquetLucene — JVM Heap Used %", `${logGroupPrefix}/parquetLucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"heap_used_percent":(?<heap_pct>\\d+)/ `,
        `filter ispresent(heap_pct)`,
        `stats avg(heap_pct) as heap_percent by bin(1m)`,
      ]),
    );

    // Merge time (cumulative)
    dashboard.addWidgets(
      nodeStatsWidget("Parquet — Merge Time (ms)", `${logGroupPrefix}/parquet/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"total_time_in_millis":(?<merge_ms>\\d+)/ `,
        `filter ispresent(merge_ms)`,
        `stats max(merge_ms) as merge_time_ms by bin(1m)`,
      ]),
      nodeStatsWidget("Lucene — Merge Time (ms)", `${logGroupPrefix}/lucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"total_time_in_millis":(?<merge_ms>\\d+)/ `,
        `filter ispresent(merge_ms)`,
        `stats max(merge_ms) as merge_time_ms by bin(1m)`,
      ]),
      nodeStatsWidget("ParquetLucene — Merge Time (ms)", `${logGroupPrefix}/parquetLucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"total_time_in_millis":(?<merge_ms>\\d+)/ `,
        `filter ispresent(merge_ms)`,
        `stats max(merge_ms) as merge_time_ms by bin(1m)`,
      ]),
    );

    // GC time
    dashboard.addWidgets(
      nodeStatsWidget("Parquet — Young GC Time (ms)", `${logGroupPrefix}/parquet/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"young":\\{"collection_count":\\d+,"collection_time_in_millis":(?<gc_ms>\\d+)/ `,
        `filter ispresent(gc_ms)`,
        `stats max(gc_ms) as young_gc_ms by bin(1m)`,
      ]),
      nodeStatsWidget("Lucene — Young GC Time (ms)", `${logGroupPrefix}/lucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"young":\\{"collection_count":\\d+,"collection_time_in_millis":(?<gc_ms>\\d+)/ `,
        `filter ispresent(gc_ms)`,
        `stats max(gc_ms) as young_gc_ms by bin(1m)`,
      ]),
      nodeStatsWidget("ParquetLucene — Young GC Time (ms)", `${logGroupPrefix}/parquetLucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"young":\\{"collection_count":\\d+,"collection_time_in_millis":(?<gc_ms>\\d+)/ `,
        `filter ispresent(gc_ms)`,
        `stats max(gc_ms) as young_gc_ms by bin(1m)`,
      ]),
    );

    // Indexing — docs indexed (cumulative)
    dashboard.addWidgets(
      nodeStatsWidget("Parquet — Docs Indexed", `${logGroupPrefix}/parquet/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"index_total":(?<idx_total>\\d+)/ `,
        `filter ispresent(idx_total)`,
        `stats max(idx_total) as docs_indexed by bin(1m)`,
      ]),
      nodeStatsWidget("Lucene — Docs Indexed", `${logGroupPrefix}/lucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"index_total":(?<idx_total>\\d+)/ `,
        `filter ispresent(idx_total)`,
        `stats max(idx_total) as docs_indexed by bin(1m)`,
      ]),
      nodeStatsWidget("ParquetLucene — Docs Indexed", `${logGroupPrefix}/parquetLucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"index_total":(?<idx_total>\\d+)/ `,
        `filter ispresent(idx_total)`,
        `stats max(idx_total) as docs_indexed by bin(1m)`,
      ]),
    );

    // Store size (bytes on disk)
    dashboard.addWidgets(
      nodeStatsWidget("Parquet — Store Size (bytes)", `${logGroupPrefix}/parquet/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"size_in_bytes":(?<store_bytes>\\d+)/ `,
        `filter ispresent(store_bytes)`,
        `stats max(store_bytes) as store_size by bin(1m)`,
      ]),
      nodeStatsWidget("Lucene — Store Size (bytes)", `${logGroupPrefix}/lucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"size_in_bytes":(?<store_bytes>\\d+)/ `,
        `filter ispresent(store_bytes)`,
        `stats max(store_bytes) as store_size by bin(1m)`,
      ]),
      nodeStatsWidget("ParquetLucene — Store Size (bytes)", `${logGroupPrefix}/parquetLucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"size_in_bytes":(?<store_bytes>\\d+)/ `,
        `filter ispresent(store_bytes)`,
        `stats max(store_bytes) as store_size by bin(1m)`,
      ]),
    );

    // Search — query total and query time
    dashboard.addWidgets(
      nodeStatsWidget("Parquet — Search Queries", `${logGroupPrefix}/parquet/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"query_total":(?<q_total>\\d+)/ `,
        `filter ispresent(q_total)`,
        `stats max(q_total) as query_total by bin(1m)`,
      ]),
      nodeStatsWidget("Lucene — Search Queries", `${logGroupPrefix}/lucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"query_total":(?<q_total>\\d+)/ `,
        `filter ispresent(q_total)`,
        `stats max(q_total) as query_total by bin(1m)`,
      ]),
      nodeStatsWidget("ParquetLucene — Search Queries", `${logGroupPrefix}/parquetLucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"query_total":(?<q_total>\\d+)/ `,
        `filter ispresent(q_total)`,
        `stats max(q_total) as query_total by bin(1m)`,
      ]),
    );

    // Flush time (cumulative)
    dashboard.addWidgets(
      nodeStatsWidget("Parquet — Flush Time (ms)", `${logGroupPrefix}/parquet/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"flush":\\{"total":\\d+,"periodic":\\d+,"total_time_in_millis":(?<flush_ms>\\d+)/ `,
        `filter ispresent(flush_ms)`,
        `stats max(flush_ms) as flush_time_ms by bin(1m)`,
      ]),
      nodeStatsWidget("Lucene — Flush Time (ms)", `${logGroupPrefix}/lucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"flush":\\{"total":\\d+,"periodic":\\d+,"total_time_in_millis":(?<flush_ms>\\d+)/ `,
        `filter ispresent(flush_ms)`,
        `stats max(flush_ms) as flush_time_ms by bin(1m)`,
      ]),
      nodeStatsWidget("ParquetLucene — Flush Time (ms)", `${logGroupPrefix}/parquetLucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"flush":\\{"total":\\d+,"periodic":\\d+,"total_time_in_millis":(?<flush_ms>\\d+)/ `,
        `filter ispresent(flush_ms)`,
        `stats max(flush_ms) as flush_time_ms by bin(1m)`,
      ]),
    );

    // Native/Virtual memory (includes Rust allocations + mmap)
    dashboard.addWidgets(
      nodeStatsWidget("Parquet — Process Virtual Mem (bytes)", `${logGroupPrefix}/parquet/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"total_virtual_in_bytes":(?<virt_bytes>\\d+)/ `,
        `filter ispresent(virt_bytes)`,
        `stats max(virt_bytes) as virtual_mem by bin(1m)`,
      ]),
      nodeStatsWidget("Lucene — Process Virtual Mem (bytes)", `${logGroupPrefix}/lucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"total_virtual_in_bytes":(?<virt_bytes>\\d+)/ `,
        `filter ispresent(virt_bytes)`,
        `stats max(virt_bytes) as virtual_mem by bin(1m)`,
      ]),
      nodeStatsWidget("ParquetLucene — Process Virtual Mem (bytes)", `${logGroupPrefix}/parquetLucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"total_virtual_in_bytes":(?<virt_bytes>\\d+)/ `,
        `filter ispresent(virt_bytes)`,
        `stats max(virt_bytes) as virtual_mem by bin(1m)`,
      ]),
    );

    // MMap'd buffers (Lucene segment files mapped into memory)
    dashboard.addWidgets(
      nodeStatsWidget("Parquet — MMap Buffers (bytes)", `${logGroupPrefix}/parquet/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"mapped":\\{"count":\\d+,"used_in_bytes":(?<mmap_bytes>\\d+)/ `,
        `filter ispresent(mmap_bytes)`,
        `stats max(mmap_bytes) as mmap_used by bin(1m)`,
      ]),
      nodeStatsWidget("Lucene — MMap Buffers (bytes)", `${logGroupPrefix}/lucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"mapped":\\{"count":\\d+,"used_in_bytes":(?<mmap_bytes>\\d+)/ `,
        `filter ispresent(mmap_bytes)`,
        `stats max(mmap_bytes) as mmap_used by bin(1m)`,
      ]),
      nodeStatsWidget("ParquetLucene — MMap Buffers (bytes)", `${logGroupPrefix}/parquetLucene/node-stats`, [
        `fields @timestamp, @message`,
        `parse @message /"mapped":\\{"count":\\d+,"used_in_bytes":(?<mmap_bytes>\\d+)/ `,
        `filter ispresent(mmap_bytes)`,
        `stats max(mmap_bytes) as mmap_used by bin(1m)`,
      ]),
    );

    new cdk.CfnOutput(this, "CloudWatchDashboard", {
      value: `https://${this.region}.console.aws.amazon.com/cloudwatch/home?region=${this.region}#dashboards/dashboard/OpenSearch-${runId}`,
    });

    // =========================================================================
    // Run ID
    // =========================================================================
    new cdk.CfnOutput(this, "RunID", { value: runId });
    new cdk.CfnOutput(this, "S3ResultsPath", { value: `s3://${s3ProfileBucket}/runs/${runId}/` });
  }
}
