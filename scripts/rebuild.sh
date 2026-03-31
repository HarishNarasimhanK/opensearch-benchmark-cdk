#!/bin/bash
set -exo pipefail

# =============================================================================
# rebuild.sh — Full rebuild of DataFusion OpenSearch on an existing EC2 instance
#
# Mirrors user-data-datafusion.sh but skips dependency installation (already done on first boot).
# Usage: ssh into the datafusion instance and run: bash rebuild.sh
# =============================================================================

REPO="${DATAFUSION_REPO:-https://github.com/opensearch-project/OpenSearch.git}"
BRANCH="${DATAFUSION_BRANCH:-feature/datafusion}"
SQL_REPO="${DATAFUSION_SQL_REPO:-https://github.com/bharath-techie/sql.git}"
SQL_BRANCH="${DATAFUSION_SQL_BRANCH:-substrait-plan}"
JVM_HEAP="${JVM_HEAP:-8g}"

echo "=== Rebuild started at $(date) ==="
echo "Repo:       $REPO"
echo "Branch:     $BRANCH"
echo "SQL Repo:   $SQL_REPO"
echo "SQL Branch: $SQL_BRANCH"

# --- Stop OpenSearch if running ---
echo "Stopping OpenSearch..."
pkill -f 'org.opensearch.bootstrap.OpenSearch' || true
sleep 2

# --- Clean previous build artifacts ---
echo "Cleaning previous artifacts..."
rm -rf ~/datafusion-opensearch-src ~/datafusion-opensearch ~/datafusion-sql-plugin
rm -f ~/datafusion-opensearch-run.log
crontab -r 2>/dev/null || true

# --- Step 1: Clone and build OpenSearch ---
echo "Cloning $REPO (branch: $BRANCH)..."
git clone --branch "$BRANCH" "$REPO" ~/datafusion-opensearch-src
cd ~/datafusion-opensearch-src && ./gradlew publishToMavenLocal -x missingJavadoc

# --- Step 2: Clone and build SQL plugin ---
echo "Cloning SQL plugin..."
git clone --branch "$SQL_BRANCH" "$SQL_REPO" ~/datafusion-sql-plugin
cd ~/datafusion-sql-plugin && ./gradlew publishToMavenLocal

# --- Step 3: Build local distribution ---
echo "Building localDistro..."
cd ~/datafusion-opensearch-src && ./gradlew localDistro -x missingJavadoc

# --- Step 4: Extract distribution ---
echo "Extracting distribution..."
mkdir -p ~/datafusion-opensearch
cp -r ~/datafusion-opensearch-src/build/distribution/local/opensearch-*/* ~/datafusion-opensearch/

# --- Step 5: Build and install plugins ---
echo "Building plugins..."
cd ~/datafusion-opensearch-src && ./gradlew :plugins:engine-datafusion:bundlePlugin :sandbox:plugins:analytics-engine:bundlePlugin -x missingJavadoc
~/datafusion-opensearch/bin/opensearch-plugin install --batch org.opensearch.plugin:opensearch-job-scheduler:3.3.0.0
~/datafusion-opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/datafusion-sql-plugin/plugin/build/distributions/opensearch-sql-3.3.0.0-SNAPSHOT.zip
~/datafusion-opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/datafusion-opensearch-src/sandbox/plugins/analytics-engine/build/distributions/analytics-engine-3.3.0-SNAPSHOT.zip

# Remove duplicate jars to avoid jar hell
PLUGIN_DIR=~/datafusion-opensearch/plugins
NEW_ZIP=~/datafusion-opensearch-src/plugins/engine-datafusion/build/distributions/engine-datafusion-3.3.0-SNAPSHOT.zip
NEW_JARS=$(unzip -l "$NEW_ZIP" | grep '\.jar$' | awk '{print $NF}' | xargs -I{} basename {})
for jar in $NEW_JARS; do
  found=$(find "$PLUGIN_DIR" -name "$jar" 2>/dev/null)
  if [ -n "$found" ]; then
    echo "Removing duplicate jar: $found"
    rm -f $found
  fi
done
~/datafusion-opensearch/bin/opensearch-plugin install --batch file:///home/ec2-user/datafusion-opensearch-src/plugins/engine-datafusion/build/distributions/engine-datafusion-3.3.0-SNAPSHOT.zip

# --- Step 6: Configure OpenSearch ---
cat > ~/datafusion-opensearch/config/opensearch.yml << 'EOF'
node.name: node-1
cluster.name: datafusion-cluster
network.host: 0.0.0.0
cluster.initial_cluster_manager_nodes: ["node-1"]
EOF

# --- Step 7: Configure JVM heap ---
sed -i "s/^-Xms.*/-Xms${JVM_HEAP}/" ~/datafusion-opensearch/config/jvm.options
sed -i "s/^-Xmx.*/-Xmx${JVM_HEAP}/" ~/datafusion-opensearch/config/jvm.options

# --- Step 8: Setup profiler cron ---
sudo systemctl enable crond
sudo systemctl start crond
echo '*/5 * * * * /home/ec2-user/opensearch-test-automation/profiler/profile-opensearch.sh >> /home/ec2-user/profile-cron.log 2>&1' | crontab -

# --- Step 9: Start OpenSearch ---
echo "Starting OpenSearch..."
nohup ~/datafusion-opensearch/bin/opensearch > ~/datafusion-opensearch-run.log 2>&1 &

echo "=== Rebuild complete at $(date) ==="
echo "Tail logs: tail -f ~/datafusion-opensearch-run.log"
