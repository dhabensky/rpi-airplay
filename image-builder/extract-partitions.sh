#!/bin/bash
# Extracts a base RPi disk image's two partitions to plain directories,
# without loop-mounting the raw image (see the plan's "No privileged
# containers" section): dd out each partition's raw bytes by offset (pure
# file I/O), then debugfs/mcopy read the filesystem image files directly.
#
# Usage: image-builder/extract-partitions.sh <base.img> <out-boot-dir> <out-root-dir>
# Intended to run inside the shared Dockerfile tooling image, which has
# e2fsprogs/dosfstools/mtools/fdisk installed.
set -euo pipefail

img="${1:?usage: $0 <base.img> <out-boot-dir> <out-root-dir>}"
outboot="${2:?}"
outroot="${3:?}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Parse the MBR partition table: expects exactly 2 partitions (FAT32 boot,
# ext4 root), the standard DietPi/Raspberry Pi OS layout.
eval "$(sfdisk -d "$img" | awk -F'[ :,=]+' '
  /img1/{print "P1_START="$3; print "P1_SIZE="$5}
  /img2/{print "P2_START="$3; print "P2_SIZE="$5}
')"
if [ -z "${P1_START:-}" ] || [ -z "${P2_START:-}" ]; then
  echo "ERROR: expected exactly 2 partitions in $img, got:" >&2
  sfdisk -d "$img" >&2
  exit 1
fi

dd if="$img" of="$work/boot.raw" bs=512 skip="$P1_START" count="$P1_SIZE" conv=notrunc status=none
dd if="$img" of="$work/root.raw" bs=512 skip="$P2_START" count="$P2_SIZE" conv=notrunc status=none

mkdir -p "$outboot" "$outroot"
rm -rf "${outboot:?}"/* "${outroot:?}"/*
mcopy -s -i "$work/boot.raw" ::/ "$outboot/"
debugfs -R "rdump / $outroot" "$work/root.raw" >/dev/null

# debugfs rdump can't recreate special files (no mknod/mkfifo/socket
# support) -- it silently substitutes an empty regular file for each
# device node instead. Harmless for most of the build, but a regular
# /dev/null is only writable by its owner (root), so any step that
# chroots in as a non-root user and needs to write to /dev/null (e.g.
# apt's https acquire method, running as _apt, draining a response body
# it doesn't need) gets EACCES -- confirmed via strace to be the actual
# cause of an apt-get update hang against snapshot.debian.org, which
# happens to trigger that codepath where dietpi.com/archive.raspberrypi.com
# don't. Recreate the standard minimal /dev nodes for real.
rm -f "$outroot/dev/null" "$outroot/dev/zero" "$outroot/dev/full" \
      "$outroot/dev/random" "$outroot/dev/urandom" \
      "$outroot/dev/tty" "$outroot/dev/console" "$outroot/dev/ptmx"
mknod -m 666 "$outroot/dev/null" c 1 3
mknod -m 666 "$outroot/dev/zero" c 1 5
mknod -m 666 "$outroot/dev/full" c 1 7
mknod -m 666 "$outroot/dev/random" c 1 8
mknod -m 666 "$outroot/dev/urandom" c 1 9
mknod -m 666 "$outroot/dev/tty" c 5 0
mknod -m 600 "$outroot/dev/console" c 5 1
mknod -m 666 "$outroot/dev/ptmx" c 5 2

echo "Extracted boot partition -> $outboot ($(find "$outboot" -type f | wc -l) files)"
echo "Extracted root partition -> $outroot ($(find "$outroot" -type f | wc -l) files)"
