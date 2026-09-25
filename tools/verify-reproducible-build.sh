#!/bin/bash
# Builds uxplay twice, independently, and sha256-compares the result.
# Expected: bit-identical -- this is fully within our control (pinned base
# image digest, SOURCE_DATE_EPOCH, -ffile-prefix-map), unlike matching the
# binary already deployed on the live Pi (whose original build environment
# can't be reconstructed). No --no-cache variant needed here: the actual
# compile runs via `docker run` (tools/build-uxplay.sh), which always
# executes fresh -- there's no docker-build layer cache for it to hide
# behind in the first place.
set -euo pipefail
cd "$(dirname "$0")/.."

# In-repo, not mktemp -d: the Docker VM shares this repo but not the host's
# temp dirs, so builds there never reach the host side at all. Kept after the
# run, so the diffoscope hint below has something to point at.
out="build/verify-repro"
rm -rf "$out"
mkdir -p "$out"

echo "==> Build 1"
./tools/build-uxplay.sh "$out/uxplay-1"

echo "==> Build 2 (independent run)"
./tools/build-uxplay.sh "$out/uxplay-2"

sha1=$(sha256sum "$out/uxplay-1" | cut -d' ' -f1)
sha2=$(sha256sum "$out/uxplay-2" | cut -d' ' -f1)

echo "build 1: $sha1"
echo "build 2: $sha2"

if [ "$sha1" = "$sha2" ]; then
  echo "PASS: bit-identical across independent builds"
  exit 0
else
  echo "FAIL: builds differ -- not reproducible. Investigate with diffoscope:"
  echo "  diffoscope $out/uxplay-1 $out/uxplay-2"
  exit 1
fi
