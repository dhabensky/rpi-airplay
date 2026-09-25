#!/bin/bash
# Asserts a binary a Docker build was supposed to write actually landed on
# the host, so a caller can't hand a 0-byte file to whatever comes next.
# Shared by every build script and Makefile rule that produces a binary.
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

echo "ERROR: build artifact $reason: $path" >&2
if [ "$reason" = "missing" ]; then
  echo "  Either the build never produced it, or it went somewhere the host" >&2
  echo "  cannot see." >&2
else
  echo "  A Docker build only reaches paths the VM shares with the host." >&2
fi
echo "  Build into this repo's own build/ directory: any temp dir outside the" >&2
echo "  repo (mktemp -d's /var/folders/..., /tmp) may not be shared." >&2
# Leave nothing behind that a later step could mistake for a build result --
# tools/pytest's uxplay_binary fixture reuses whatever exists at its path.
rm -rf -- "$path"
exit 1
