import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as elbv2 from "aws-cdk-lib/aws-elasticloadbalancingv2";
import * as targets from "aws-cdk-lib/aws-elasticloadbalancingv2-targets";
import * as s3assets from "aws-cdk-lib/aws-s3-assets";
import * as cw from "aws-cdk-lib/aws-cloudwatch";
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
  s3ProfileBucket: string;
  instanceType: string;
  ebsSizeGb: number;
  ebsIops: number;
  ebsThroughput: number;
  jvmHeap: string;
  parquetJvmHeap?: string;
  benchmarkEnabled: boolean;
  benchmarkInstanceType: string;
  benchmarkEbsSizeGb: number;
  benchmarkEbsIops: number;
  benchmarkEbsThroughput: number;
  parquetWorkloadRepo: string;
  parquetWorkloadBranch: string;
  luceneWorkloadRepo: string;
  luceneWorkloadBranch: string;
  testIterations: number;
  ingestPercentage: number;
  luceneEnabled: boolean;
  luceneRepo: string;
  luceneBranch: string;
  parquetLuceneEnabled: boolean;
  parquetLuceneWorkloadRepo: string;
  parquetLuceneWorkloadBranch: string;
  clusterMode: string;
  dataNodeCount: number;
  metricsStoreHost: string;
  metricsStorePort: string;
  metricsStoreSecure: string;
  runId: string;
  runIdPrefix: string;
}

export class OpenSearchCodeGuruStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: OpenSearchCodeGuruStackProps) {
    super(scope, id, props);

    const { branch, opensearchRepo, vpcId, subnetId, subnetAz, securityGroupId, keyPairName,
      s3ProfileBucket, instanceType, ebsSizeGb, ebsIops,
      ebsThroughput, jvmHeap, benchmarkEnabled, benchmarkInstanceType, benchmarkEbsSizeGb,
      benchmarkEbsIops, benchmarkEbsThroughput,
      parquetWorkloadRepo, parquetWorkloadBranch, luceneWorkloadRepo, luceneWorkloadBranch,
      testIterations, ingestPercentage, luceneEnabled, luceneRepo, luceneBranch,
      parquetLuceneEnabled, parquetLuceneWorkloadRepo, parquetLuceneWorkloadBranch,
      clusterMode, dataNodeCount, metricsStoreHost, metricsStorePort, metricsStoreSecure, runId, runIdPrefix } = props;

    const parquetJvmHeap = props.parquetJvmHeap || jvmHeap;

    const isMultiNode = clusterMode === "multi";
    const clusterTag = `${id}-parquet-cluster`;
    // Log group prefix: "/opensearch" for normal, "/opensearch/nightly" for nightly
    const logGroupPrefix = runIdPrefix ? `/opensearch/${runIdPrefix}` : "/opensearch";

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
        .replace(/\{\{LOG_GROUP_PREFIX\}\}/g, logGroupPrefix);

      const inst = createInstance(nodeId, ltId, script, instanceType, ebsSizeGb, ebsIops, ebsThroughput);
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
      .replace(/\{\{PARQUET_BRANCH\}\}/g, branch)
      .replace(/\{\{PARQUET_REPO\}\}/g, opensearchRepo)
      .replace(/\{\{LUCENE_BRANCH\}\}/g, luceneBranch)
      .replace(/\{\{LUCENE_REPO\}\}/g, luceneRepo)
      .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket)
      .replace(/\{\{RUN_ID\}\}/g, runId)
      .replace(/\{\{LOG_GROUP_PREFIX\}\}/g, logGroupPrefix);

    const builderInstance = createInstance("BuilderInstance", "BuilderLt", builderScript, instanceType, ebsSizeGb, ebsIops, ebsThroughput);
    cdk.Tags.of(builderInstance).add("Name", `${id}-Builder-${runId}`);

    new cdk.CfnOutput(this, "A1_BuilderSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${builderInstance.instancePublicDnsName}` });
    new cdk.CfnOutput(this, "A2_BuilderLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${builderInstance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });

    // =========================================================================
    // Parquet OpenSearch: single-node or multi-node cluster
    // =========================================================================
    let parquetEndpoint: string;
    let parquetInstanceId: string = "";

    if (isMultiNode) {
      // --- Multi-node: 3 managers + N data nodes + internal ALB ---
      const seedManager = createParquetInstance("SeedManager", "SeedManagerLt", "clusterManager-seed", "cluster_manager");
      new cdk.CfnOutput(this, "B1_SeedManagerSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${seedManager.instancePublicDnsName}` });

      for (let i = 2; i <= 3; i++) {
        createParquetInstance(`Manager${i}`, `Manager${i}Lt`, `clusterManager-${i}`, "cluster_manager");
      }

      const dataInstances: ec2.Instance[] = [];
      for (let i = 1; i <= dataNodeCount; i++) {
        const data = createParquetInstance(`DataNode${i}`, `DataNode${i}Lt`, `dataNode-${i}`, "data, ingest");
        dataInstances.push(data);
        if (i === 1) parquetInstanceId = data.instanceId;  // Use first data node for CloudWatch dashboard
        new cdk.CfnOutput(this, `B2DataNode${i}SSH`, { value: `ssh -i ~/${keyPairName}.pem ec2-user@${data.instancePublicDnsName}` });
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

      new cdk.CfnOutput(this, "B3_ClusterALBUrl", { value: `http://${alb.loadBalancerDnsName}:9200` });
      new cdk.CfnOutput(this, "B4_ClusterMode", { value: `multi (3 managers + ${dataNodeCount} data nodes)` });

    } else {
      // --- Single-node (default) ---
      const instance = createParquetInstance("ParquetInstance", "ParquetLt", "node", "");
      parquetEndpoint = instance.instancePrivateIp;
      parquetInstanceId = instance.instanceId;

      new cdk.CfnOutput(this, "B1_ParquetSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${instance.instancePublicDnsName}` });
      new cdk.CfnOutput(this, "B2_ParquetSetupLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${instance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
      new cdk.CfnOutput(this, "B3_ParquetRuntimeLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${instance.instancePublicDnsName} "tail -f ~/parquet-opensearch-run.log"` });
      new cdk.CfnOutput(this, "B4_ParquetPrivateIp", { value: instance.instancePrivateIp });
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
          .replace(/\{\{JVM_HEAP\}\}/g, jvmHeap)
          .replace(/\{\{SCRIPTS_S3_PATH\}\}/g, scriptsS3Path)
          .replace(/\{\{CLUSTER_MODE\}\}/g, clusterMode)
          .replace(/\{\{CLUSTER_TAG\}\}/g, luceneClusterTag)
          .replace(/\{\{NODE_NAME\}\}/g, nodeName)
          .replace(/\{\{NODE_ROLES\}\}/g, nodeRoles)
          .replace(/\{\{BENCHMARK_ENABLED\}\}/g, String(benchmarkEnabled))
          .replace(/\{\{RUN_ID\}\}/g, runId)
          .replace(/\{\{LOG_GROUP_PREFIX\}\}/g, logGroupPrefix);

        const inst = createInstance(nodeId, ltId, script, instanceType, ebsSizeGb, ebsIops, ebsThroughput);
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
        new cdk.CfnOutput(this, "C1_LuceneSeedManagerSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${luceneSeedManager.instancePublicDnsName}` });

        for (let i = 2; i <= 3; i++) {
          createLuceneInstance(`LuceneManager${i}`, `LuceneManager${i}Lt`, `clusterManager-${i}`, "cluster_manager");
        }

        const luceneDataInstances: ec2.Instance[] = [];
        for (let i = 1; i <= dataNodeCount; i++) {
          const data = createLuceneInstance(`LuceneDataNode${i}`, `LuceneDataNode${i}Lt`, `dataNode-${i}`, "data, ingest");
          luceneDataInstances.push(data);
          if (i === 1) luceneInstanceId = data.instanceId;  // Use first data node for CloudWatch dashboard
          new cdk.CfnOutput(this, `C2LuceneDataNode${i}SSH`, { value: `ssh -i ~/${keyPairName}.pem ec2-user@${data.instancePublicDnsName}` });
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

        new cdk.CfnOutput(this, "C3_LuceneClusterALBUrl", { value: `http://${luceneAlb.loadBalancerDnsName}:9200` });
        new cdk.CfnOutput(this, "C4_LuceneClusterMode", { value: `multi (3 managers + ${dataNodeCount} data nodes)` });

      } else {
        // --- Single-node (default) ---
        const luceneInstance = createLuceneInstance("LuceneInstance", "LuceneLt", "node", "");
        luceneEndpoint = luceneInstance.instancePrivateIp;
        luceneInstanceId = luceneInstance.instanceId;

        new cdk.CfnOutput(this, "C1_LuceneSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${luceneInstance.instancePublicDnsName}` });
        new cdk.CfnOutput(this, "C2_LuceneSetupLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${luceneInstance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
        new cdk.CfnOutput(this, "C3_LucenePrivateIp", { value: luceneInstance.instancePrivateIp });
      }
    }

    // =========================================================================
    // ParquetLucene OpenSearch: same binary as Parquet, different workload (indexed_parquet)
    // =========================================================================
    let parquetLuceneEndpoint = "";
    let parquetLuceneInstanceId: string = "";
    if (parquetLuceneEnabled) {
      const createParquetLuceneInstance = (nodeId: string, ltId: string, nodeName: string, nodeRoles: string): ec2.Instance => {
        const script = fs.readFileSync(path.join(__dirname, "..", "scripts", "user-data-parquetLucene.sh"), "utf-8")
          .replace(/\{\{S3_PROFILE_BUCKET\}\}/g, s3ProfileBucket)
          .replace(/\{\{JVM_HEAP\}\}/g, parquetJvmHeap)
          .replace(/\{\{SCRIPTS_S3_PATH\}\}/g, scriptsS3Path)
          .replace(/\{\{CLUSTER_MODE\}\}/g, clusterMode)
          .replace(/\{\{CLUSTER_TAG\}\}/g, `${id}-parquetLucene-cluster`)
          .replace(/\{\{NODE_NAME\}\}/g, nodeName)
          .replace(/\{\{NODE_ROLES\}\}/g, nodeRoles)
          .replace(/\{\{BENCHMARK_ENABLED\}\}/g, String(benchmarkEnabled))
          .replace(/\{\{RUN_ID\}\}/g, runId)
          .replace(/\{\{LOG_GROUP_PREFIX\}\}/g, logGroupPrefix);

        const inst = createInstance(nodeId, ltId, script, instanceType, ebsSizeGb, ebsIops, ebsThroughput);
        cdk.Tags.of(inst).add("Name", `${id}-ParquetLucene-${runId}-${nodeName}`);
        return inst;
      };

      const parquetLuceneInstance = createParquetLuceneInstance("ParquetLuceneInstance", "ParquetLuceneLt", "node", "");
      parquetLuceneEndpoint = parquetLuceneInstance.instancePrivateIp;
      parquetLuceneInstanceId = parquetLuceneInstance.instanceId;

      new cdk.CfnOutput(this, "D1_ParquetLuceneSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${parquetLuceneInstance.instancePublicDnsName}` });
      new cdk.CfnOutput(this, "D2_ParquetLuceneSetupLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${parquetLuceneInstance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
      new cdk.CfnOutput(this, "D3_ParquetLuceneRuntimeLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${parquetLuceneInstance.instancePublicDnsName} "tail -f ~/parquetLucene-opensearch-run.log"` });
      new cdk.CfnOutput(this, "D4_ParquetLucenePrivateIp", { value: parquetLuceneInstance.instancePrivateIp });
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
        .replace(/\{\{PARQUET_PRIVATE_IP\}\}/g, parquetEndpoint)
        .replace(/\{\{LUCENE_PRIVATE_IP\}\}/g, luceneEndpoint)
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

      new cdk.CfnOutput(this, "D1_BenchmarkSSH", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${benchmarkInstance.instancePublicDnsName}` });
      new cdk.CfnOutput(this, "D2_BenchmarkSetupLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${benchmarkInstance.instancePublicDnsName} "tail -f /var/log/user-data.log"` });
      new cdk.CfnOutput(this, "D3_BenchmarkRunLog", { value: `ssh -i ~/${keyPairName}.pem ec2-user@${benchmarkInstance.instancePublicDnsName} "tail -f ~/benchmark-run.log"` });
    }

    // =========================================================================
    // Metrics Store
    // =========================================================================
    if (metricsStoreHost && benchmarkEnabled) {
      new cdk.CfnOutput(this, "E1_MetricsStoreEndpoint", { value: `https://${metricsStoreHost}` });
      new cdk.CfnOutput(this, "E2_MetricsStoreDashboard", { value: `https://${metricsStoreHost}/_dashboards (access via SSH tunnel: ssh -i ~/${keyPairName}.pem -L 5601:${metricsStoreHost}:443 ec2-user@<benchmark-dns> then open https://localhost:5601/_dashboards)` });
    }

    // =========================================================================
    // CloudWatch Dashboard — side-by-side Parquet vs Lucene system metrics
    // =========================================================================
    const metricsNamespace = `OpenSearch/${runId}`;

    // Use instance IDs to identify engines (EngineRole custom dimension is not supported by CW agent)
    const pqInstanceId = parquetInstanceId;
    const luInstanceId = luceneInstanceId;

    const cwMetric = (metricName: string, instanceId: string, extraDims?: Record<string, string>): cw.Metric =>
      new cw.Metric({
        namespace: metricsNamespace, metricName,
        dimensionsMap: { InstanceId: instanceId, ...extraDims },
        period: cdk.Duration.seconds(60), statistic: "Average",
      });

    const sideBySide = (title: string, metricName: string, yLabel: string, extraDims?: Record<string, string>): cw.GraphWidget => {
      const left = [cwMetric(metricName, pqInstanceId, extraDims).with({ label: "Parquet", color: "#FF6B35" })];
      const right = luInstanceId ? [cwMetric(metricName, luInstanceId, extraDims).with({ label: "Lucene", color: "#004E89" })] : [];
      return new cw.GraphWidget({
        title, width: 24, height: 6, left, right,
        leftYAxis: { label: yLabel }, rightYAxis: { label: yLabel },
      });
    };

    const dashboard = new cw.Dashboard(this, "BenchmarkDashboard", {
      dashboardName: `OpenSearch-${runId}`,
    });

    dashboard.addWidgets(
      new cw.TextWidget({
        markdown: `# Parquet vs Lucene — ${runId}\nNamespace: \`${metricsNamespace}\`\n\nNote: Graphs use InstanceId to distinguish engines. If graphs are empty, the instances may still be starting up. Check back in 30-40 minutes after deploy.`,
        width: 24, height: 2,
      }),
    );
    dashboard.addWidgets(sideBySide("CPU Usage (%)", "cpu_usage_user", "%", { cpu: "cpu-total" }));
    dashboard.addWidgets(sideBySide("Memory Used (%)", "mem_used_percent", "%"));
    dashboard.addWidgets(sideBySide("Disk I/O — Write Bytes", "diskio_write_bytes", "bytes", { name: "nvme0n1p1" }));
    dashboard.addWidgets(sideBySide("Disk I/O — Read Bytes", "diskio_read_bytes", "bytes", { name: "nvme0n1p1" }));
    dashboard.addWidgets(sideBySide("Network — Bytes Sent", "net_bytes_sent", "bytes", { interface: "ens5" }));
    dashboard.addWidgets(sideBySide("Network — Bytes Received", "net_bytes_recv", "bytes", { interface: "ens5" }));

    // vmstat memory stats from logs — separate widgets per metric for proper scaling
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
      vmstatWidget("Parquet — Free Memory (KB)", `${logGroupPrefix}/parquet/vmstat`, "free"),
      vmstatWidget("Parquet — Buffer (KB)", `${logGroupPrefix}/parquet/vmstat`, "buff"),
      vmstatWidget("Parquet — Cache (KB)", `${logGroupPrefix}/parquet/vmstat`, "cache"),
    );
    dashboard.addWidgets(
      vmstatWidget("Lucene — Free Memory (KB)", `${logGroupPrefix}/lucene/vmstat`, "free"),
      vmstatWidget("Lucene — Buffer (KB)", `${logGroupPrefix}/lucene/vmstat`, "buff"),
      vmstatWidget("Lucene — Cache (KB)", `${logGroupPrefix}/lucene/vmstat`, "cache"),
    );

    new cdk.CfnOutput(this, "G1_CloudWatchDashboard", {
      value: `https://${this.region}.console.aws.amazon.com/cloudwatch/home?region=${this.region}#dashboards/dashboard/OpenSearch-${runId}`,
    });

    // =========================================================================
    // Run ID
    // =========================================================================
    new cdk.CfnOutput(this, "F1_RunID", { value: runId });
    new cdk.CfnOutput(this, "F2_S3ResultsPath", { value: `s3://${s3ProfileBucket}/runs/${runId}/` });
  }
}
