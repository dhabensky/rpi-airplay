#!/bin/bash
# Builds uxplay (colima/Docker on the arm64 Mac host, no cross-compilation
# needed) and deploys the binary to a Pi already provisioned via setup.sh,
# then restarts the service.
#
# Usage: ./deploy.sh [user@host]   (default target: tools/pissh's)
set -euo pipefail
cd "$(dirname "$0")/.."

# The address itself lives in tools/pissh, which reads UXPLAY_PI_HOST.
if [ $# -gt 0 ]; then
  export UXPLAY_PI_HOST="$1"
fi

echo "==> Building uxplay_debug"
./tools/build-uxplay.sh build/uxplay_debug
file build/uxplay_debug

echo "==> Deploying to $(tools/pissh -t)"
tools/pissh -p build/uxplay_debug /usr/local/bin/uxplay_debug
tools/pissh 'chmod +x /usr/local/bin/uxplay_debug && systemctl restart uxplay && sleep 2 && systemctl is-active uxplay'
