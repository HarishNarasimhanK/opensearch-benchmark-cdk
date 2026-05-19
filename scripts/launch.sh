#!/bin/bash
# Opens the benchmark configuration UI in your browser.
# Usage: ./scripts/launch.sh  (or just ./launch from project root)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UI_FILE="${SCRIPT_DIR}/launch-ui.html"

if [ ! -f "$UI_FILE" ]; then
  echo "❌ UI file not found: $UI_FILE"
  exit 1
fi

echo "🚀 Opening benchmark config UI..."

if command -v open &> /dev/null; then
  open "$UI_FILE"
elif command -v xdg-open &> /dev/null; then
  xdg-open "$UI_FILE"
else
  echo "   Open this in your browser: file://${UI_FILE}"
fi
