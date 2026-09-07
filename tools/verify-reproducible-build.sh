#!/bin/bash
# Builds uxplay via ../Dockerfile.uxplay-buildtest twice (one with --no-cache
# to rule out layer-cache reuse masking nondeterminism) and sha256-compares
# the extracted binary. Expected result: bit-identical -- this is fully
# within our control (pinned base image digest, SOURCE_DATE_EPOCH,
# -ffile-prefix-map), unlike matching the binary already deployed on the
# live Pi (whose original build environment can't be reconstructed).
set -euo pipefail
cd "$(dirname "$0")/.."

extract_binary() {
  local tag="$1" out="$2"
  docker build -q -t "$tag" -f Dockerfile.uxplay-buildtest . >/dev/null
  local id
  id=$(docker create "$tag")
  docker cp "$id:/usr/local/bin/uxplay" "$out"
  docker rm "$id" >/dev/null
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "==> Build 1 (normal, may use layer cache)"
extract_binary uxplay-repro-check-1 "$tmp/uxplay-1"

echo "==> Build 2 (--no-cache, forces every layer to actually re-run)"
docker build --no-cache -q -t uxplay-repro-check-2 -f Dockerfile.uxplay-buildtest . >/dev/null
id=$(docker create uxplay-repro-check-2)
docker cp "$id:/usr/local/bin/uxplay" "$tmp/uxplay-2"
docker rm "$id" >/dev/null

sha1=$(sha256sum "$tmp/uxplay-1" | cut -d' ' -f1)
sha2=$(sha256sum "$tmp/uxplay-2" | cut -d' ' -f1)

echo "build 1: $sha1"
echo "build 2: $sha2"

if [ "$sha1" = "$sha2" ]; then
  echo "PASS: bit-identical across independent builds"
  exit 0
else
  echo "FAIL: builds differ -- not reproducible. Investigate with diffoscope:"
  echo "  diffoscope $tmp/uxplay-1 $tmp/uxplay-2"
  exit 1
fi
