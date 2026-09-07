#!/bin/bash
# Builds uxplay via ../Dockerfile.uxplay-buildtest (colima/Docker on the arm64
# Mac host, no cross-compilation needed) and deploys the binary to a Pi
# already provisioned via setup.sh, then restarts the service.
#
# Usage: ./deploy.sh [user@host]   (default: root@192.168.1.34)
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-root@192.168.1.34}"

echo "==> Building uxplay-buildtest image"
docker build -t uxplay-buildtest -f Dockerfile.uxplay-buildtest .

echo "==> Extracting binary"
id=$(docker create uxplay-buildtest)
docker cp "$id:/usr/local/bin/uxplay" ./uxplay_debug
docker rm "$id" >/dev/null
file ./uxplay_debug

echo "==> Deploying to $TARGET"
scp ./uxplay_debug "$TARGET:/usr/local/bin/uxplay_debug"
ssh "$TARGET" 'chmod +x /usr/local/bin/uxplay_debug && systemctl restart uxplay && sleep 2 && systemctl is-active uxplay'
