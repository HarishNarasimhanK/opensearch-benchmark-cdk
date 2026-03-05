#!/bin/bash
set -exo pipefail
exec > /var/log/user-data.log 2>&1

# --- Install dependencies ---
yum install -y git java-21-amazon-corretto-devel protobuf-compiler protobuf-devel rust cargo cmake
yum groupinstall -y 'Development Tools'
export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto
echo 'export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto' >> /etc/profile.d/java.sh
sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' >> /etc/sysctl.conf

# --- Step 1: Clone and build OpenSearch ---
su -l ec2-user -c 'git clone --branch {{BRANCH}} https://github.com/opensearch-project/OpenSearch.git /home/ec2-user/opensearch-src'
su -l ec2-user -c 'cd /home/ec2-user/opensearch-src && ./gradlew publishToMavenLocal'

# --- Step 2: Clone and build SQL plugin (skipped) ---
# su -l ec2-user -c 'git clone --branch {{SQL_PLUGIN_BRANCH}} {{SQL_PLUGIN_REPO}} /home/ec2-user/sql-plugin'
# su -l ec2-user -c 'cd /home/ec2-user/sql-plugin && ./gradlew publishToMavenLocal'

# --- Step 3: Build local distribution ---
su -l ec2-user -c 'cd /home/ec2-user/opensearch-src && ./gradlew localDistro'

# --- Step 4: Extract the local distribution ---
su -l ec2-user -c 'mkdir -p /home/ec2-user/opensearch && cp -r /home/ec2-user/opensearch-src/distribution/local/opensearch-*/* /home/ec2-user/opensearch/'

# --- Step 5: Install plugins (skipped) ---
# su -l ec2-user -c '/home/ec2-user/opensearch/bin/opensearch-plugin install --batch org.opensearch.plugin:opensearch-job-scheduler:3.3.0.0'
# su -l ec2-user -c '/home/ec2-user/opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/sql-plugin/plugin/build/distributions/opensearch-sql-plugin-*.zip'
# su -l ec2-user -c '/home/ec2-user/opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/opensearch-src/plugins/engine-datafusion/build/distributions/engine-datafusion-*.zip'

# --- Step 6: CodeGuru Profiler agent ---
su -l ec2-user -c 'mkdir -p /home/ec2-user/codeguru'
su -l ec2-user -c 'curl -o /home/ec2-user/codeguru/codeguru-profiler-java-agent-standalone.jar https://d1osg35nybn3tt.cloudfront.net/com/amazonaws/codeguru-profiler-java-agent-standalone/1.2.4/codeguru-profiler-java-agent-standalone-1.2.4.jar'
printf '\n-javaagent:/home/ec2-user/codeguru/codeguru-profiler-java-agent-standalone.jar="profilingGroupName:{{PROFILING_GROUP_NAME}},region:{{REGION}},heapSummaryEnabled:true"\n' >> /home/ec2-user/opensearch/config/jvm.options
chown ec2-user:ec2-user /home/ec2-user/opensearch/config/jvm.options

# --- Step 7: Start OpenSearch ---
cat > /home/ec2-user/run-opensearch.sh << 'SCRIPT'
#!/bin/bash
set -exo pipefail
export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto
/home/ec2-user/opensearch/bin/opensearch
SCRIPT
chmod +x /home/ec2-user/run-opensearch.sh
chown ec2-user:ec2-user /home/ec2-user/run-opensearch.sh

su -l ec2-user -c 'nohup /home/ec2-user/run-opensearch.sh > /home/ec2-user/opensearch-run.log 2>&1 &'
