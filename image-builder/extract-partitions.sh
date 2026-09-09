#!/bin/bash
# Extracts a base RPi disk image's two partitions to plain directories,
# without loop-mounting the raw image (see the plan's "No privileged
# containers" section): dd out each partition's raw bytes by offset (pure
# file I/O), then debugfs/mcopy read the filesystem image files directly.
#
# Usage: image-builder/extract-partitions.sh <base.img> <out-boot-dir> <out-root-dir>
# Intended to run inside the image-builder container (Dockerfile.image-builder),
# which has e2fsprogs/dosfstools/mtools/fdisk installed.
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

echo "Extracted boot partition -> $outboot ($(find "$outboot" -type f | wc -l) files)"
echo "Extracted root partition -> $outroot ($(find "$outroot" -type f | wc -l) files)"
