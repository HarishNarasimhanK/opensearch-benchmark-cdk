#!/bin/bash
set -exo pipefail

# Full rebuild of OpenSearch on an existing EC2 instance.
# Mirrors everything in user-data.sh but skips dependency installation (already done on first boot).
# Usage: ssh into the instance and run: bash rebuild.sh

REPO="${OPENSEARCH_REPO:-https://github.com/alchemist51/OpenSearch.git}"
BRANCH="${OPENSEARCH_BRANCH:-indexing-changes}"
S3_BUCKET="${S3_PROFILE_BUCKET:-profiler-async}"
JVM_HEAP="${JVM_HEAP:-8g}"

echo "=== Rebuild started at $(date) ==="
echo "Repo:   $REPO"
echo "Branch: $BRANCH"

# --- Stop OpenSearch if running ---
echo "Stopping OpenSearch..."
pkill -f 'org.opensearch.bootstrap.OpenSearch' || true
sleep 2

# --- Clean everything ---
echo "Cleaning all previous artifacts..."
rm -rf ~/opensearch-src ~/opensearch ~/async-profiler ~/profiles ~/profile-opensearch.sh
rm -f ~/opensearch-run.log ~/profile-cron.log
crontab -r 2>/dev/null || true

# --- Step 1: Clone and build OpenSearch ---
echo "Cloning $REPO (branch: $BRANCH)..."
git clone --branch "$BRANCH" "$REPO" ~/opensearch-src

echo "Building publishToMavenLocal..."
cd ~/opensearch-src && ./gradlew publishToMavenLocal

# --- Step 3: Build local distribution ---
echo "Building localDistro..."
./gradlew localDistro

# --- Step 4: Extract distribution ---
echo "Extracting distribution..."
mkdir -p ~/opensearch
cp -r ~/opensearch-src/build/distribution/local/opensearch-*/* ~/opensearch/

# --- Step 6: Install async-profiler ---
echo "Installing async-profiler..."
mkdir -p ~/async-profiler
curl -L -o ~/async-profiler/async-profiler.tar.gz \
  https://github.com/async-profiler/async-profiler/releases/download/v3.0/async-profiler-3.0-linux-arm64.tar.gz
tar xzf ~/async-profiler/async-profiler.tar.gz -C ~/async-profiler --strip-components=1

# --- Profiling script ---
cat > ~/profile-opensearch.sh << SCRIPT
#!/bin/bash
set -eo pipefail
PROFILER=~/async-profiler/bin/asprof
OUTPUT_DIR=~/profiles
S3_BUCKET=$S3_BUCKET
mkdir -p "\$OUTPUT_DIR"
TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
HOSTNAME=\$(hostname)
PID=\$(pgrep -f opensearch-src || pgrep -f 'org.opensearch.bootstrap.OpenSearch' || true)
if [ -z "\$PID" ]; then
  echo "OpenSearch not running, skipping profile"
  exit 0
fi
FILENAME="cpu_\${HOSTNAME}_\${TIMESTAMP}.html"
\$PROFILER -d 60 -f "\$OUTPUT_DIR/\$FILENAME" "\$PID"
aws s3 cp "\$OUTPUT_DIR/\$FILENAME" "s3://\$S3_BUCKET/\$HOSTNAME/\$FILENAME"
SCRIPT
chmod +x ~/profile-opensearch.sh

# --- Cron: run CPU profile every 5 minutes ---
echo "Setting up cron..."
sudo systemctl enable crond
sudo systemctl start crond
echo '*/5 * * * * /home/ec2-user/profile-opensearch.sh >> /home/ec2-user/profile-cron.log 2>&1' | crontab -

# --- Logrotate for OpenSearch and profiler logs ---
sudo tee /etc/logrotate.d/opensearch-profiler > /dev/null << 'LOGROTATE'
/home/ec2-user/opensearch-run.log
/home/ec2-user/profile-cron.log {
    size 100M
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0644 ec2-user ec2-user
}
LOGROTATE

# --- Step 7: Configure OpenSearch for external access ---
cat > ~/opensearch/config/opensearch.yml << 'EOF'
node.name: node-1
cluster.name: my-application
network.host: 0.0.0.0
cluster.initial_cluster_manager_nodes: ["node-1"]
EOF

# --- Step 7b: Configure JVM heap ---
sed -i "s/^-Xms.*/-Xms${JVM_HEAP}/" ~/opensearch/config/jvm.options
sed -i "s/^-Xmx.*/-Xmx${JVM_HEAP}/" ~/opensearch/config/jvm.options

# --- Step 8: Start OpenSearch ---
echo "Starting OpenSearch..."
nohup ~/opensearch/bin/opensearch > ~/opensearch-run.log 2>&1 &

echo "=== Rebuild complete at $(date) ==="
echo "Tail logs: tail -f ~/opensearch-run.log"
