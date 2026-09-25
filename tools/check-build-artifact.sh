#!/bin/bash
# Asserts a binary a Docker build was supposed to write actually landed on
# the host, so a caller can't hand a 0-byte file to whatever comes next.
# Usage: tools/check-build-artifact.sh <path>
set -euo pipefail

path="${1:?usage: $0 <artifact-path>}"

if [ ! -e "$path" ]; then
  reason="missing"
elif [ ! -f "$path" ]; then
  reason="not a regular file"
elif [ ! -s "$path" ]; then
  reason="empty (0 bytes)"
else
  exit 0
fi

# Docker shares $HOME into its VM but not macOS /tmp, so a bind mount under
# /tmp leaves the host path untouched while the container still exits 0.
echo "ERROR: build artifact $reason: $path" >&2
echo "  A Docker build only reaches paths the VM shares with the host --" >&2
echo "  build into this repo's own build/ directory, never macOS /tmp." >&2
exit 1
