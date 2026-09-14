#!/bin/bash
# Deliberate, rare action (run by hand via `make refresh-apt-lists`, never
# automatically): runs `apt-get update` ONCE against the base image's real
# sources.list and captures the resulting /var/lib/apt/lists/* index files
# into image-builder/apt-lists/ (checked into git -- package metadata, not
# binaries, ~10MB total).
#
# customize-root.sh installs from this frozen, checked-in index instead of
# calling `apt-get update` itself. Without this, every image build queries
# whatever Debian/DietPi/RPi Foundation currently publish, and a package
# pinned in apt-packages.lock can vanish from the live index the moment
# upstream ships a newer point/security release (old versions are dropped
# from the published index, not just superseded). Freezing the index means
# apt always resolves the SAME pinned versions, and packages only ever
# change when this script is deliberately re-run.
#
# apt-packages.lock and image-builder/apt-lists/ must be regenerated
# TOGETHER, from the same apt-get update snapshot -- a lock file pin that
# doesn't appear in the frozen index will fail to resolve. Run this first,
# then re-capture apt-packages.lock's pins from the same run (see that
# file's header for the exact one-liner).
#
# Requires: Docker. Does NOT commit -- review and commit
# image-builder/apt-lists/ explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILDER_TAG=rpi-airplay-image-builder
ROOT_VOLUME=rpi-airplay-apt-refresh-root
BOOT_VOLUME=rpi-airplay-apt-refresh-boot

if [ ! -f build/dietpi-base.img ]; then
  echo "ERROR: build/dietpi-base.img not found -- run 'make base-image' first" >&2
  exit 1
fi

cleanup() { docker volume rm -f "$ROOT_VOLUME" "$BOOT_VOLUME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Building image-builder container"
docker build -q -t "$BUILDER_TAG" -f Dockerfile.image-builder . >/dev/null

echo "==> Extracting base image's root partition (for its real sources.list)"
cleanup
docker run --rm \
  -v "$PWD/build":/build:ro \
  -v "$PWD/image-builder":/image-builder:ro \
  -v "$BOOT_VOLUME":/dietpi-boot \
  -v "$ROOT_VOLUME":/dietpi-root \
  "$BUILDER_TAG" bash /image-builder/extract-partitions.sh \
    /build/dietpi-base.img /dietpi-boot /dietpi-root

echo "==> Running apt-get update against the real sources, capturing the index"
mkdir -p image-builder/apt-lists
rm -f image-builder/apt-lists/*
docker run --rm \
  -v "$ROOT_VOLUME":/rootdir \
  -v "$PWD/image-builder/apt-lists":/out \
  "$BUILDER_TAG" bash -c '
    set -euo pipefail
    cp /etc/resolv.conf /rootdir/etc/resolv.conf
    chroot /rootdir apt-get update -qq
    cp /rootdir/var/lib/apt/lists/*_InRelease /rootdir/var/lib/apt/lists/*_Packages* /out/
  '

echo "==> Captured $(ls image-builder/apt-lists | wc -l | tr -d ' ') index files ($(du -sh image-builder/apt-lists | cut -f1))"
echo "    Review and commit: git add image-builder/apt-lists"
echo "    Now re-capture image-builder/apt-packages.lock from the SAME apt-get update run (see its header)"
