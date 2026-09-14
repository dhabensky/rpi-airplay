#!/bin/bash
# Deliberate, rare action (run by hand via `make refresh-buildenv-apt-lists`,
# never automatically): runs `apt-get update` ONCE against the plain Debian
# base image Dockerfile pins and captures the resulting index into
# apt-lists/ (checked into git -- package metadata, not binaries).
#
# Dockerfile installs its own tooling packages (cmake, the gstreamer-
# plugins-* used to compute the vendored GStreamer closure, etc.) against
# this frozen index instead of calling `apt-get update` itself, so the
# exact byte content of anything computed from those packages
# (build/vendor-gstreamer/) stays fixed across rebuilds regardless of
# when Docker happens to invalidate its layer cache. Captures the plain
# Debian base image's own sources.list -- a different apt source than
# image-builder/apt-lists/, which captures the customized DietPi
# rootfs's.
#
# Requires: Docker. Does NOT commit -- review and commit apt-lists/
# explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

BASE_DIGEST="debian@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132"

mkdir -p apt-lists
rm -f apt-lists/*
apt_lists_abs="$(cd apt-lists && pwd)"

docker run --rm -v "$apt_lists_abs":/out "$BASE_DIGEST" sh -c '
  set -eu
  apt-get update -qq
  cp /var/lib/apt/lists/*_InRelease /var/lib/apt/lists/*_Packages* /out/
'

echo "==> Captured $(ls apt-lists | wc -l | tr -d ' ') index files ($(du -sh apt-lists | cut -f1))"
echo "    Review and commit: git add apt-lists"
