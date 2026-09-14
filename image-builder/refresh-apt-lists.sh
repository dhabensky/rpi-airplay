#!/bin/bash
# Deliberate, rare action (run by hand via `make refresh-apt-lists`, never
# automatically): runs `apt-get update` ONCE against a pinned source list
# and captures the resulting /var/lib/apt/lists/* index files into
# image-builder/apt-lists/ (checked into git -- package metadata, not
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
# Freezing the index alone isn't enough for the four Debian suites: the
# base image's own sources.list points them at live deb.debian.org, and
# apt-get install resolves the actual .deb DOWNLOAD from whatever
# sources.list says at install time, regardless of which index is frozen
# -- the same live archive that drops superseded versions. Before running
# apt-get update, this script overwrites those four lines with
# snapshot.debian.org's permanent, date-pinned URLs (DEBIAN_SNAPSHOT /
# DEBIAN_SECURITY_SNAPSHOT below) -- a service built for exactly this:
# every version ever published, served forever at a fixed timestamp.
# customize-root.sh points its own chroot at the same URLs at install
# time (see that script) so the captured index and the actual download
# source always agree. dietpi.com and archive.raspberrypi.com (in
# sources.list.d/, untouched here) have no equivalent permanent archive
# -- their packages are vendored by hand instead, see
# image-builder/refresh-vendored-debs.sh.
#
# apt-packages.lock and image-builder/apt-lists/ must be regenerated
# TOGETHER, from the same apt-get update snapshot -- a lock file pin that
# doesn't appear in the frozen index will fail to resolve. Run this first,
# then re-capture apt-packages.lock's pins from the same run (see that
# file's header for the exact one-liner).
#
# To move the pin forward in time later: pick new DEBIAN_SNAPSHOT /
# DEBIAN_SECURITY_SNAPSHOT timestamps from snapshot.debian.org's own
# listing (e.g. `curl -s 'https://snapshot.debian.org/archive/debian/?year=YYYY&month=M'`),
# confirm each with a `curl -I .../dists/<suite>/InRelease` (expect a 302,
# not 404) before committing to it, update the two variables below and
# customize-root.sh's matching ones, then re-run this script.
#
# Requires: Docker. Does NOT commit -- review and commit
# image-builder/apt-lists/ explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

# Confirmed reachable (InRelease returns 302, not 404) for every suite
# these cover: trixie/trixie-updates/trixie-backports (DEBIAN_SNAPSHOT)
# and trixie-security (DEBIAN_SECURITY_SNAPSHOT), both comfortably after
# apt-packages.lock's 2026-09-09 pin capture.
DEBIAN_SNAPSHOT=20260914T142711Z
DEBIAN_SECURITY_SNAPSHOT=20260914T183713Z

BUILDER_TAG=rpi-airplay-buildenv
ROOT_VOLUME=rpi-airplay-apt-refresh-root
BOOT_VOLUME=rpi-airplay-apt-refresh-boot

if [ ! -f build/dietpi-base.img ]; then
  echo "ERROR: build/dietpi-base.img not found -- run 'make base-image' first" >&2
  exit 1
fi

cleanup() { docker volume rm -f "$ROOT_VOLUME" "$BOOT_VOLUME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Building image-builder container"
docker build -q -t "$BUILDER_TAG" -f Dockerfile . >/dev/null

echo "==> Extracting base image's root partition (for its real sources.list)"
cleanup
docker run --rm \
  -v "$PWD/build":/build:ro \
  -v "$PWD/image-builder":/image-builder:ro \
  -v "$BOOT_VOLUME":/dietpi-boot \
  -v "$ROOT_VOLUME":/dietpi-root \
  "$BUILDER_TAG" bash /image-builder/extract-partitions.sh \
    /build/dietpi-base.img /dietpi-boot /dietpi-root

echo "==> Pinning Debian's sources.list to snapshot.debian.org ($DEBIAN_SNAPSHOT / $DEBIAN_SECURITY_SNAPSHOT)"
mkdir -p image-builder/apt-lists
rm -f image-builder/apt-lists/*
docker run --rm \
  -v "$ROOT_VOLUME":/rootdir \
  -v "$PWD/image-builder/apt-lists":/out \
  -e DEBIAN_SNAPSHOT="$DEBIAN_SNAPSHOT" \
  -e DEBIAN_SECURITY_SNAPSHOT="$DEBIAN_SECURITY_SNAPSHOT" \
  "$BUILDER_TAG" bash -c '
    set -euo pipefail
    cat > /rootdir/etc/apt/sources.list <<EOF
deb https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ trixie main contrib non-free non-free-firmware
deb https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ trixie-updates main contrib non-free non-free-firmware
deb https://snapshot.debian.org/archive/debian-security/${DEBIAN_SECURITY_SNAPSHOT}/ trixie-security main contrib non-free non-free-firmware
deb https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ trixie-backports main contrib non-free non-free-firmware
EOF
    cp /etc/resolv.conf /rootdir/etc/resolv.conf
    chroot /rootdir apt-get update -qq
    cp /rootdir/var/lib/apt/lists/*_InRelease /rootdir/var/lib/apt/lists/*_Packages* /out/
  '

echo "==> Captured $(ls image-builder/apt-lists | wc -l | tr -d ' ') index files ($(du -sh image-builder/apt-lists | cut -f1))"
echo "    Review and commit: git add image-builder/apt-lists"
echo "    Now re-capture image-builder/apt-packages.lock from the SAME apt-get update run (see its header)"
