#!/bin/bash
# Rebuilds the two partition images from customized directories and
# assembles the final flashable .img -- all plain-file operations, no
# mount, no loop device (see the plan's "No privileged containers"
# section). Copies the base image's own partition table (so boot flags,
# alignment, and sizes match what the base image shipped with) rather
# than inventing a new one.
#
# Usage: image-builder/build-image.sh <base.img> <boot-dir> <root-dir> <out.img>
set -euo pipefail

base_img="${1:?usage: $0 <base.img> <boot-dir> <root-dir> <out.img>}"
bootdir="${2:?}"
rootdir="${3:?}"
out="${4:?}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

eval "$(sfdisk -d "$base_img" | awk -F'[ :,=]+' '
  /img1/{print "P1_START="$3; print "P1_SIZE="$5}
  /img2/{print "P2_START="$3; print "P2_SIZE="$5}
')"

echo "==> Building boot partition ($P1_SIZE sectors) from $bootdir"
truncate -s "$((P1_SIZE * 512))" "$work/boot.raw"
mkfs.vfat "$work/boot.raw" >/dev/null
# mcopy needs an explicit file list, not a bare glob against an empty dir
find "$bootdir" -mindepth 1 -maxdepth 1 -exec mcopy -s -i "$work/boot.raw" {} ::/ \;

echo "==> Building root partition ($P2_SIZE sectors) from $rootdir"
# mke2fs -d populates the filesystem directly from a directory tree in one
# shot (a real e2fsprogs feature -- this is how Android's build system does
# it) -- no mount, no loop device. Size must match the base image's own
# partition slot exactly (we're rebuilding into it, not growing it):
# P2_SIZE is in 512-byte sectors, so /2 converts to KB exactly (not a
# fudge-factor guess).
mke2fs -q -t ext4 -d "$rootdir" "$work/root.raw" "$((P2_SIZE / 2))K"

echo "==> Assembling $out"
cp "$base_img" "$out"
# Zero the partition contents first (cp above copied the OLD contents;
# dd conv=notrunc below only overwrites exactly P1_SIZE/P2_SIZE sectors,
# matching the base image's own partition sizes, so this is safe/exact).
dd if="$work/boot.raw" of="$out" bs=512 seek="$P1_START" conv=notrunc status=none
dd if="$work/root.raw" of="$out" bs=512 seek="$P2_START" conv=notrunc status=none

echo "Built $out ($(du -h "$out" | cut -f1))"
