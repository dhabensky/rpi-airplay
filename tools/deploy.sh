#!/bin/bash
# Builds uxplay (colima/Docker on the arm64 Mac host, no cross-compilation
# needed) and deploys the binary to a Pi already provisioned via setup.sh,
# then restarts the service.
#
# Usage: ./deploy.sh [user@host]   (default: root@192.168.1.34)
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-root@192.168.1.34}"

echo "==> Building uxplay_debug"
./tools/build-uxplay.sh build/uxplay_debug
file build/uxplay_debug

echo "==> Deploying to $TARGET"
scp build/uxplay_debug "$TARGET:/usr/local/bin/uxplay_debug"
ssh "$TARGET" 'chmod +x /usr/local/bin/uxplay_debug && systemctl restart uxplay && sleep 2 && systemctl is-active uxplay'
