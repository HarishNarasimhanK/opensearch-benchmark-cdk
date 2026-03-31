#!/bin/bash
set -exo pipefail
exec > /var/log/user-data.log 2>&1

# =============================================================================
# user-data-benchmark.sh — Installs OSB, clones scripts repo, runs benchmarks
# =============================================================================

# --- Step 1: Install dependencies ---
yum install -y python3-pip git

# --- Step 2: Install OpenSearch Benchmark ---
su -l ec2-user -c 'pip3 install opensearch-benchmark --user'
su -l ec2-user -c 'echo "export PATH=\$HOME/.local/bin:\$PATH" >> ~/.bashrc'

# --- Step 3: Write env config ---
cat > /home/ec2-user/.opensearch-env << 'ENVEOF'
S3_BUCKET={{S3_PROFILE_BUCKET}}
DATAFUSION_HOST={{DATAFUSION_PRIVATE_IP}}
LUCENE_HOST={{LUCENE_PRIVATE_IP}}
WORKLOAD_PATH_DATAFUSION=/home/ec2-user/datafusion-workloads/clickbench
WORKLOAD_PATH_LUCENE=/home/ec2-user/lucene-workloads/clickbench
ENVEOF
chown ec2-user:ec2-user /home/ec2-user/.opensearch-env

# --- Step 4: Clone repos ---
su -l ec2-user -c 'git clone https://github.com/HarishNarasimhanK/opensearch-test-automation.git /home/ec2-user/opensearch-test-automation'
su -l ec2-user -c 'git clone -b {{WORKLOAD_BRANCH}} {{WORKLOAD_REPO}} /home/ec2-user/datafusion-workloads'
su -l ec2-user -c 'git clone https://github.com/opensearch-project/opensearch-benchmark-workloads.git /home/ec2-user/lucene-workloads'

# --- Step 5: Auto-run all benchmarks ---
su -l ec2-user -c 'nohup bash /home/ec2-user/opensearch-test-automation/benchmark/run-all.sh > /home/ec2-user/benchmark-run.log 2>&1 &'
