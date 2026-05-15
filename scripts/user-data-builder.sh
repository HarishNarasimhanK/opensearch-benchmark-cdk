#!/bin/bash
set -exo pipefail
exec > /var/log/user-data.log 2>&1

# =============================================================================
# user-data-builder.sh — Builds both Parquet and Lucene OpenSearch from
# source, packages each as tar.gz, uploads to S3, then shuts down.
#
# Parquet build: JDK 25 + Rust + sandbox localDistro + 9 plugins + native lib
# Lucene build:  JDK 21 + vanilla localDistro + discovery-ec2 plugin
#
# This instance is a temporary build machine — shuts down after uploading.
# =============================================================================

S3_BUCKET="{{S3_PROFILE_BUCKET}}"

# --- Step 1: Clean up old builds from S3 ---
echo "=== Cleaning old builds from S3 ==="
su -l ec2-user -c "aws s3 rm s3://${S3_BUCKET}/builds/ --recursive" || true

# --- Step 2: Install build dependencies ---
echo "=== Installing build dependencies ==="
yum install -y --allowerasing git amazon-cloudwatch-agent \
  tar gzip unzip wget make gcc gcc-c++ openssl-devel zlib-devel protobuf protobuf-devel
yum groupinstall -y 'Development Tools'

# JDK 21 for Lucene (system-level)
yum install -y java-21-amazon-corretto-devel

# JDK 25 for Parquet (user-level, sandbox requires 25+)
echo "=== Installing JDK 25 (Corretto) ==="
su -l ec2-user -c 'wget -q "https://corretto.aws/downloads/resources/25.0.3.9.1/amazon-corretto-25.0.3.9.1-linux-aarch64.tar.gz" -O /tmp/corretto25.tar.gz && tar xzf /tmp/corretto25.tar.gz -C $HOME && rm /tmp/corretto25.tar.gz'

# Rust for Parquet native lib
echo "=== Installing Rust ==="
su -l ec2-user -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable'

# --- Step 3: Start CloudWatch agent ---
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/user-data.log", "log_group_name": "{{LOG_GROUP_PREFIX}}/builder/user-data", "log_stream_name": "{{RUN_ID}}/{instance_id}-builder" }
        ]
      }
    }
  }
}
CWCONFIG
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

# =============================================================================
# BUILD 1: Parquet OpenSearch (sandbox + 8 plugins + native lib)
# =============================================================================
echo ""
echo "============================================"
echo "  Building Parquet OpenSearch (sandbox)"
echo "============================================"

# All Parquet build steps run as ec2-user with JDK 25 + Rust on PATH
su -l ec2-user -c '
set -exo pipefail
export JAVA_HOME=$HOME/amazon-corretto-25.0.3.9.1-linux-aarch64
export PATH=$JAVA_HOME/bin:$HOME/.cargo/bin:$PATH

SRC=$HOME/parquet-opensearch-src
DIST=$HOME/parquet-opensearch

# Clone
echo "=== Cloning OpenSearch ({{PARQUET_BRANCH}}) ==="
git clone --depth 1 --branch {{PARQUET_BRANCH}} {{PARQUET_REPO}} $SRC

# Build Rust native library (~15 min)
echo "=== Building Rust native library ==="
cd $SRC/sandbox/libs/dataformat-native/rust
cargo build -p opensearch-native-lib --release

# Build localDistro with sandbox enabled (~6 min)
echo "=== Building localDistro (sandbox) ==="
cd $SRC
./gradlew localDistro -Dsandbox.enabled=true -x javadoc -x test -x missingJavadoc

# Build arrow-flight-rpc plugin (analytics-engine depends on it) + 6 sandbox plugin zips (~1 min)
echo "=== Building plugin zips ==="
./gradlew -Dsandbox.enabled=true \
  :plugins:arrow-flight-rpc:bundlePlugin \
  :sandbox:plugins:analytics-engine:bundlePlugin \
  :sandbox:plugins:parquet-data-format:bundlePlugin \
  :sandbox:plugins:analytics-backend-datafusion:bundlePlugin \
  :sandbox:plugins:analytics-backend-lucene:bundlePlugin \
  :sandbox:plugins:dsl-query-executor:bundlePlugin \
  :sandbox:plugins:composite-engine:bundlePlugin \
  -x test -x javadoc -x missingJavadoc

# Prepare distribution directory
echo "=== Preparing Parquet distribution ==="
mkdir -p $DIST
cp -r $SRC/build/distribution/local/opensearch-*/* $DIST/

# Copy native library into distribution lib/
cp $SRC/sandbox/libs/dataformat-native/rust/target/release/libopensearch_native.so $DIST/lib/

# Install plugins (arrow-flight-rpc first, then sandbox plugins)
echo "=== Installing plugins ==="
for zip in \
  $SRC/plugins/arrow-flight-rpc/build/distributions/arrow-flight-rpc-*.zip \
  $SRC/sandbox/plugins/analytics-engine/build/distributions/analytics-engine-*.zip \
  $SRC/sandbox/plugins/parquet-data-format/build/distributions/parquet-data-format-*.zip \
  $SRC/sandbox/plugins/analytics-backend-datafusion/build/distributions/analytics-backend-datafusion-*.zip \
  $SRC/sandbox/plugins/analytics-backend-lucene/build/distributions/analytics-backend-lucene-*.zip \
  $SRC/sandbox/plugins/dsl-query-executor/build/distributions/dsl-query-executor-*.zip \
  $SRC/sandbox/plugins/composite-engine/build/distributions/composite-engine-*.zip
do
  echo "  Installing: $(basename $zip)"
  $DIST/bin/opensearch-plugin install --batch "file://$zip"
done

# Build and install job-scheduler plugin (SQL dependency)
echo "=== Building job-scheduler plugin ==="
git clone --depth 1 --branch main https://github.com/opensearch-project/job-scheduler.git $HOME/job-scheduler
cd $HOME/job-scheduler
./gradlew assemble -Dbuild.snapshot=true -x test -x javadoc
JOB_ZIP=$(find $HOME/job-scheduler/build/distributions -name "opensearch-job-scheduler-*.zip" -not -name "*sample*" | head -1)
echo "  Installing: $(basename $JOB_ZIP)"
$DIST/bin/opensearch-plugin install --batch "file://$JOB_ZIP"

# Build and install SQL plugin (provides /_plugins/_ppl endpoint)
echo "=== Building SQL plugin ==="
git clone --depth 1 --branch main https://github.com/opensearch-project/sql.git $HOME/sql-plugin
cd $HOME/sql-plugin
./gradlew publishToMavenLocal -Dbuild.snapshot=true -x test -x javadoc
SQL_ZIP=$(find $HOME/.m2/repository/org/opensearch/plugin/opensearch-sql-plugin -name "*.zip" | head -1)
echo "  Installing: $(basename $SQL_ZIP)"
$DIST/bin/opensearch-plugin install --batch "file://$SQL_ZIP"

# Install discovery-ec2 plugin (for multi-node)
echo "=== Building discovery-ec2 plugin ==="
cd $SRC
./gradlew :plugins:discovery-ec2:bundlePlugin -Dsandbox.enabled=true -x missingJavadoc 2>/dev/null && \
  DISC_ZIP=$(ls $SRC/plugins/discovery-ec2/build/distributions/discovery-ec2-*.zip | head -1) && \
  $DIST/bin/opensearch-plugin install --batch "file://$DISC_ZIP" || \
  echo "discovery-ec2 plugin build failed (non-fatal — only needed for multi-node)"

# Package and upload
echo "=== Packaging Parquet tar.gz ==="
tar czf /tmp/opensearch-parquet.tar.gz -C $DIST .
aws s3 cp /tmp/opensearch-parquet.tar.gz s3://'"${S3_BUCKET}"'/builds/opensearch-parquet.tar.gz
echo "=== Parquet build uploaded ==="

# Verify
echo "Installed plugins:"
ls $DIST/plugins/
echo "Native lib:"
ls -lh $DIST/lib/libopensearch_native.so
'

# --- Clean up Parquet source to free disk for Lucene build ---
rm -rf /home/ec2-user/parquet-opensearch-src /home/ec2-user/parquet-opensearch /tmp/opensearch-parquet.tar.gz

# =============================================================================
# BUILD 2: Lucene OpenSearch (vanilla, no sandbox plugins, JDK 21)
# =============================================================================
echo ""
echo "============================================"
echo "  Building Lucene OpenSearch"
echo "============================================"

su -l ec2-user -c '
set -exo pipefail
export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto
export PATH=$JAVA_HOME/bin:$PATH

SRC=$HOME/lucene-opensearch-src
DIST=$HOME/lucene-opensearch

# Clone and build
echo "=== Cloning OpenSearch ({{LUCENE_BRANCH}}) ==="
git clone --branch {{LUCENE_BRANCH}} {{LUCENE_REPO}} $SRC
echo "=== Building localDistro ==="
cd $SRC
./gradlew localDistro -x missingJavadoc

# Extract distribution
mkdir -p $DIST
cp -r $SRC/build/distribution/local/opensearch-*/* $DIST/

# Install discovery-ec2 plugin (for multi-node)
echo "=== Building discovery-ec2 plugin ==="
./gradlew :plugins:discovery-ec2:bundlePlugin -x missingJavadoc 2>/dev/null && \
  DISC_ZIP=$(ls $SRC/plugins/discovery-ec2/build/distributions/discovery-ec2-*.zip | head -1) && \
  $DIST/bin/opensearch-plugin install --batch "file://$DISC_ZIP" || \
  echo "discovery-ec2 plugin build failed (non-fatal — only needed for multi-node)"

# Package and upload
echo "=== Packaging Lucene tar.gz ==="
tar czf /tmp/opensearch-lucene.tar.gz -C $DIST .
aws s3 cp /tmp/opensearch-lucene.tar.gz s3://'"${S3_BUCKET}"'/builds/opensearch-lucene.tar.gz
echo "=== Lucene build uploaded ==="
'

# =============================================================================
# DONE — Upload a marker file so runtime instances know builds are ready
# =============================================================================
echo "BUILDS_COMPLETE=$(date -u +%Y%m%d_%H%M%S)" | su -l ec2-user -c "aws s3 cp - s3://${S3_BUCKET}/builds/BUILD_COMPLETE"

echo ""
echo "============================================"
echo "  Both builds complete and uploaded to S3!"
echo "  s3://${S3_BUCKET}/builds/opensearch-parquet.tar.gz"
echo "  s3://${S3_BUCKET}/builds/opensearch-lucene.tar.gz"
echo "============================================"

# --- Self-terminate to save costs ---
echo "=== Shutting down builder instance ==="
shutdown -h now
