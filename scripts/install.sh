#!/bin/bash
# Builds Reword.app and installs it to /Applications (needed for a stable Launch at Login item).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build_app.sh"
osascript -e 'tell application id "com.ou.Reword" to quit' 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -x Reword >/dev/null || break; sleep 0.25; done
pkill -x Reword 2>/dev/null || true
rm -rf /Applications/Reword.app /Applications/trans.app
ditto "$ROOT/build/Reword.app" /Applications/Reword.app
echo "Installed /Applications/Reword.app"
