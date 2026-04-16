#!/bin/bash
set -exo pipefail
exec > /var/log/user-data.log 2>&1

# =============================================================================
# user-data-builder.sh — Builds both DataFusion and Lucene OpenSearch from source,
# packages them as tar.gz, uploads to S3, then shuts down.
#
# This instance is a temporary build machine. Runtime instances download the
# pre-built tar.gz from S3 instead of building from source (~2 min vs ~25 min).
# =============================================================================

S3_BUCKET="{{S3_PROFILE_BUCKET}}"

# --- Step 1: Clean up old builds from S3 ---
echo "=== Cleaning old builds from S3 ==="
su -l ec2-user -c "aws s3 rm s3://${S3_BUCKET}/builds/ --recursive" || true

# --- Step 2: Install build dependencies ---
echo "=== Step 1: Installing build dependencies ==="
yum install -y git java-21-amazon-corretto-devel protobuf-compiler protobuf-devel rust cargo cmake amazon-cloudwatch-agent
yum groupinstall -y 'Development Tools'
export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto
echo 'export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto' >> /etc/profile.d/java.sh

# --- Step 1b: Start CloudWatch agent (streams build log to CloudWatch) ---
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/user-data.log", "log_group_name": "/opensearch/builder/user-data", "log_stream_name": "{instance_id}" }
        ]
      }
    }
  }
}
CWCONFIG
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

# =============================================================================
# BUILD 1: DataFusion OpenSearch (feature/datafusion + SQL + plugins)
# =============================================================================
echo ""
echo "============================================"
echo "  Building DataFusion OpenSearch"
echo "============================================"

# --- Clone and build OpenSearch core ---
echo "=== Cloning OpenSearch ({{BRANCH}}) ==="
su -l ec2-user -c 'git clone --branch {{BRANCH}} {{OPENSEARCH_REPO}} /home/ec2-user/datafusion-opensearch-src'
echo "=== Building OpenSearch (publishToMavenLocal) ==="
su -l ec2-user -c 'cd /home/ec2-user/datafusion-opensearch-src && ./gradlew publishToMavenLocal -x missingJavadoc'

# --- Clone and build SQL plugin ---
echo "=== Cloning SQL plugin ({{SQL_PLUGIN_BRANCH}}) ==="
su -l ec2-user -c 'git clone --branch {{SQL_PLUGIN_BRANCH}} {{SQL_PLUGIN_REPO}} /home/ec2-user/datafusion-sql-plugin'
echo "=== Building SQL plugin ==="
su -l ec2-user -c 'cd /home/ec2-user/datafusion-sql-plugin && ./gradlew publishToMavenLocal'

# --- Build local distribution ---
echo "=== Building localDistro ==="
su -l ec2-user -c 'cd /home/ec2-user/datafusion-opensearch-src && ./gradlew localDistro -x missingJavadoc'

# --- Extract distribution ---
su -l ec2-user -c 'mkdir -p /home/ec2-user/datafusion-opensearch && cp -r /home/ec2-user/datafusion-opensearch-src/build/distribution/local/opensearch-*/* /home/ec2-user/datafusion-opensearch/'

# --- Build and install plugins ---
echo "=== Building plugins ==="
su -l ec2-user -c 'cd /home/ec2-user/datafusion-opensearch-src && ./gradlew :plugins:engine-datafusion:bundlePlugin :sandbox:plugins:analytics-engine:bundlePlugin -x missingJavadoc'
su -l ec2-user -c '/home/ec2-user/datafusion-opensearch/bin/opensearch-plugin install --batch org.opensearch.plugin:opensearch-job-scheduler:3.3.0.0'
su -l ec2-user -c '/home/ec2-user/datafusion-opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/datafusion-sql-plugin/plugin/build/distributions/opensearch-sql-3.3.0.0-SNAPSHOT.zip'
su -l ec2-user -c '/home/ec2-user/datafusion-opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/datafusion-opensearch-src/sandbox/plugins/analytics-engine/build/distributions/analytics-engine-3.3.0-SNAPSHOT.zip'

# Remove duplicate jars to avoid jar hell
su -l ec2-user -c '
PLUGIN_DIR=/home/ec2-user/datafusion-opensearch/plugins
NEW_ZIP=/home/ec2-user/datafusion-opensearch-src/plugins/engine-datafusion/build/distributions/engine-datafusion-3.3.0-SNAPSHOT.zip
NEW_JARS=$(unzip -l "$NEW_ZIP" | grep "\.jar$" | awk "{print \$NF}" | xargs -I{} basename {})
for jar in $NEW_JARS; do
  found=$(find "$PLUGIN_DIR" -name "$jar" 2>/dev/null)
  if [ -n "$found" ]; then
    echo "Removing duplicate jar to avoid jar hell: $found"
    rm -f $found
  fi
done
'
su -l ec2-user -c '/home/ec2-user/datafusion-opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/datafusion-opensearch-src/plugins/engine-datafusion/build/distributions/engine-datafusion-3.3.0-SNAPSHOT.zip'

# --- Build discovery-ec2 plugin (useful for multi-node later) ---
echo "=== Building discovery-ec2 plugin ==="
su -l ec2-user -c 'cd /home/ec2-user/datafusion-opensearch-src && ./gradlew :plugins:discovery-ec2:bundlePlugin -x missingJavadoc 2>/dev/null' && \
  su -l ec2-user -c 'DISC_ZIP=$(ls /home/ec2-user/datafusion-opensearch-src/plugins/discovery-ec2/build/distributions/discovery-ec2-*-SNAPSHOT.zip | head -1) && /home/ec2-user/datafusion-opensearch/bin/opensearch-plugin install --batch "file://$DISC_ZIP"' || \
  echo "discovery-ec2 plugin build failed (non-fatal — only needed for multi-node)"

# --- Package and upload DataFusion ---
echo "=== Packaging DataFusion tar.gz ==="
su -l ec2-user -c 'cd /home/ec2-user && tar czf /tmp/opensearch-datafusion.tar.gz -C /home/ec2-user/datafusion-opensearch .'
echo "=== Uploading DataFusion tar.gz to S3 ==="
su -l ec2-user -c "aws s3 cp /tmp/opensearch-datafusion.tar.gz s3://${S3_BUCKET}/builds/opensearch-datafusion.tar.gz"
echo "=== DataFusion build uploaded ==="

# =============================================================================
# BUILD 2: Lucene OpenSearch (main branch, no plugins)
# =============================================================================
echo ""
echo "============================================"
echo "  Building Lucene OpenSearch"
echo "============================================"

# --- Clone and build ---
echo "=== Cloning OpenSearch ({{LUCENE_BRANCH}}) ==="
su -l ec2-user -c 'git clone --branch {{LUCENE_BRANCH}} {{LUCENE_REPO}} /home/ec2-user/lucene-opensearch-src'
echo "=== Building localDistro ==="
su -l ec2-user -c 'cd /home/ec2-user/lucene-opensearch-src && ./gradlew localDistro -x missingJavadoc'

# --- Extract distribution ---
su -l ec2-user -c 'mkdir -p /home/ec2-user/lucene-opensearch && cp -r /home/ec2-user/lucene-opensearch-src/build/distribution/local/opensearch-*/* /home/ec2-user/lucene-opensearch/'

# --- Package and upload Lucene ---
echo "=== Packaging Lucene tar.gz ==="
su -l ec2-user -c 'cd /home/ec2-user && tar czf /tmp/opensearch-lucene.tar.gz -C /home/ec2-user/lucene-opensearch .'
echo "=== Uploading Lucene tar.gz to S3 ==="
su -l ec2-user -c "aws s3 cp /tmp/opensearch-lucene.tar.gz s3://${S3_BUCKET}/builds/opensearch-lucene.tar.gz"
echo "=== Lucene build uploaded ==="

# =============================================================================
# DONE — Upload a marker file so runtime instances know builds are ready
# =============================================================================
echo "BUILDS_COMPLETE=$(date -u +%Y%m%d_%H%M%S)" | su -l ec2-user -c "aws s3 cp - s3://${S3_BUCKET}/builds/BUILD_COMPLETE"

echo ""
echo "============================================"
echo "  Both builds complete and uploaded to S3!"
echo "  s3://${S3_BUCKET}/builds/opensearch-datafusion.tar.gz"
echo "  s3://${S3_BUCKET}/builds/opensearch-lucene.tar.gz"
echo "============================================"

# --- Self-terminate to save costs ---
echo "=== Shutting down builder instance ==="
shutdown -h now
