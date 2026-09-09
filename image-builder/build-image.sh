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
# -i pins the FAT volume ID to whatever $rootdir/etc/fstab's /boot/firmware
# entry expects, same reasoning and same real-world failure as the root
# UUID fix below: mkfs.vfat generates a fresh random volume ID every run by
# default, but fstab still names the base image's original one. Confirmed
# via the same chroot-against-a-real-loop-device test as the root UUID bug
# -- this one surfaces one step later in fs_partition_resize.sh, trying to
# mount /boot/firmware by its (stale) UUID to import dietpi-wifi.txt etc.
boot_uuid=$(awk '$2 == "/boot/firmware" && $1 ~ /^UUID=/ {sub(/^UUID=/, "", $1); gsub(/-/, "", $1); print $1; exit}' "$rootdir/etc/fstab")
if [ -z "$boot_uuid" ]; then
  echo "ERROR: no UUID= /boot/firmware entry found in $rootdir/etc/fstab" >&2
  exit 1
fi
mkfs.vfat -i "$boot_uuid" "$work/boot.raw" >/dev/null
# mcopy needs an explicit file list, not a bare glob against an empty dir
find "$bootdir" -mindepth 1 -maxdepth 1 -exec mcopy -s -i "$work/boot.raw" {} ::/ \;

echo "==> Building root partition ($P2_SIZE sectors) from $rootdir"
# mke2fs -d populates the filesystem directly from a directory tree in one
# shot (a real e2fsprogs feature -- this is how Android's build system does
# it) -- no mount, no loop device. Size must match the base image's own
# partition slot exactly (we're rebuilding into it, not growing it):
# P2_SIZE is in 512-byte sectors, so /2 converts to KB exactly (not a
# fudge-factor guess).
#
# -U must pin the filesystem UUID to whatever $rootdir/etc/fstab's root
# entry already expects: mke2fs generates a fresh random UUID on every run
# by default, but /etc/fstab is copied unmodified from the base image and
# still names the ORIGINAL filesystem's UUID. Without this, the kernel
# still boots fine (root= on the kernel cmdline uses the partition table's
# PARTUUID, which we do preserve), but the first later `mount -o
# remount,rw /` -- literally DietPi's first first-boot action, in
# fs_partition_resize.sh -- fails outright ("can't find UUID=...") because
# plain `mount <mountpoint>` resolves the source via fstab, not the live
# mount table. Confirmed by chroot-testing fs_partition_resize.sh directly
# against a real loop-mounted build (systemd-nspawn can't reproduce this at
# all -- it never has a real block device backing root, so DietPi's resize
# script always takes its "assuming container system" skip path instead).
root_uuid=$(awk '$2 == "/" && $1 ~ /^UUID=/ {sub(/^UUID=/, "", $1); print $1; exit}' "$rootdir/etc/fstab")
if [ -z "$root_uuid" ]; then
  echo "ERROR: no UUID= root entry found in $rootdir/etc/fstab" >&2
  exit 1
fi
mke2fs -q -t ext4 -U "$root_uuid" -d "$rootdir" "$work/root.raw" "$((P2_SIZE / 2))K"

echo "==> Assembling $out"
cp "$base_img" "$out"
# Zero the partition contents first (cp above copied the OLD contents;
# dd conv=notrunc below only overwrites exactly P1_SIZE/P2_SIZE sectors,
# matching the base image's own partition sizes, so this is safe/exact).
dd if="$work/boot.raw" of="$out" bs=512 seek="$P1_START" conv=notrunc status=none
dd if="$work/root.raw" of="$out" bs=512 seek="$P2_START" conv=notrunc status=none

echo "Built $out ($(du -h "$out" | cut -f1))"
