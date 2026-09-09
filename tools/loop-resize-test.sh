#!/bin/bash
# Boots-adjacent test that systemd-nspawn structurally cannot do:
# nspawn never has a real block device backing its root filesystem, so
# DietPi's own first-boot partition/filesystem-resize logic
# (fs_partition_resize.sh) always takes its "assuming container system"
# skip path there -- an entire class of bug (anything depending on a real
# /dev/mmcblk0-style device) is invisible to `make test-boot`.
#
# This loop-mounts the actual built image (via a real /dev/loopN, not a
# bind-mounted directory) and runs fs_partition_resize.sh in a chroot
# against it -- the exact same code path DietPi's own systemd unit
# (dietpi-fs_partition_resize.service) runs on real first boot, before
# the resize service disables itself. Two real bugs were found this way
# that nspawn-based testing could never have caught (see
# image-builder/build-image.sh's -U/-i comments and REBUILD-STATUS.md):
# mke2fs/mkfs.vfat generate a fresh random filesystem UUID/volume-ID on
# every build, while /etc/fstab keeps referencing the base image's
# original one -- so the very first `mount -o remount,rw /` in DietPi's
# own first-boot script failed outright, on every single boot (the
# service only disables itself *after* that remount succeeds).
#
# Must run on a real Linux host with root (colima's own VM here, not
# nested inside the Docker image-builder container -- needs real loop
# devices). Never touches build/rpi-airplay.img itself (works on a copy).
#
# Usage: run via `make test-resize` (shells into colima automatically).
set -euo pipefail

IMG=/Users/dhabensky/rpi-airplay/build/rpi-airplay.img
WORK=/tmp/loop-resize-test
TESTIMG="$WORK/test.img"

[ -f "$IMG" ] || { echo "ERROR: $IMG not found -- run 'make image' first" >&2; exit 1; }

cleanup() {
  set +e
  umount "$WORK/root/proc" 2>/dev/null
  umount "$WORK/root/dev" 2>/dev/null
  umount "$WORK/root/boot/firmware" 2>/dev/null
  umount "$WORK/root/tmp" 2>/dev/null
  umount "$WORK/boot" 2>/dev/null
  umount "$WORK/root" 2>/dev/null
  [ -n "${LOOPDEV:-}" ] && losetup -d "$LOOPDEV" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK/root" "$WORK/boot"
cp "$IMG" "$TESTIMG"

LOOPDEV=$(losetup -P -f --show "$TESTIMG")
echo "==> Loop device: $LOOPDEV"
partprobe "$LOOPDEV" 2>/dev/null || true
sleep 1

mount "${LOOPDEV}p2" "$WORK/root"
mount "${LOOPDEV}p1" "$WORK/boot"
mount --bind "$WORK/boot" "$WORK/root/boot/firmware"
mount --bind /dev "$WORK/root/dev"
mount -t proc proc "$WORK/root/proc"

fail=0

echo
echo "=== filesystem UUID vs /etc/fstab consistency ==="
root_uuid_fstab=$(awk '$2 == "/" && $1 ~ /^UUID=/ {sub(/^UUID=/, "", $1); print $1; exit}' "$WORK/root/etc/fstab")
root_uuid_real=$(blkid -s UUID -o value "${LOOPDEV}p2")
if [ "$root_uuid_fstab" = "$root_uuid_real" ]; then
  echo "PASS: root filesystem UUID matches fstab ($root_uuid_real)"
else
  echo "FAIL: root filesystem UUID mismatch -- fstab expects $root_uuid_fstab, actual is $root_uuid_real"
  fail=1
fi
boot_uuid_fstab=$(awk '$2 == "/boot/firmware" && $1 ~ /^UUID=/ {sub(/^UUID=/, "", $1); print $1; exit}' "$WORK/root/etc/fstab")
boot_uuid_real=$(blkid -s UUID -o value "${LOOPDEV}p1")
if [ "$boot_uuid_fstab" = "$boot_uuid_real" ]; then
  echo "PASS: boot (FAT) volume ID matches fstab ($boot_uuid_real)"
else
  echo "FAIL: boot volume ID mismatch -- fstab expects $boot_uuid_fstab, actual is $boot_uuid_real"
  fail=1
fi

echo
echo "=== config.txt / dietpi.txt content assertions ==="
# Every one of these was a real, previously-invisible bug found only by an
# actual flash+boot+photographed-console-screen cycle -- config.txt/
# dietpi.txt live on the boot partition, which no other local test mounts
# at all (nspawn's -D mode only ever sees the root filesystem). Asserted
# here, statically, so a regression fails in seconds, not after a full
# card round-trip.
assert_line() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qx "$pattern" "$file"; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc -- expected line '$pattern' not found in $file"
    fail=1
  fi
}
assert_line "$WORK/boot/config.txt" 'dtoverlay=vc4-kms-v3d' \
  "KMS/DRM overlay enabled (uxplay's kmssink needs /dev/dri/card0)"
assert_line "$WORK/boot/config.txt" 'gpu_mem_1024=128' \
  "GPU memory split is 128 (not the base image's default 16)"
assert_line "$WORK/boot/config.txt" 'temp_limit=75' \
  "thermal throttle limit matches golden-reference (75, not default 65)"
assert_line "$WORK/boot/cmdline.txt" \
  'root=PARTUUID=7d86c605-02 rootfstype=ext4 rootwait fsck.repair=yes net.ifnames=0 logo.nologo console=ttyS0,115200 console=tty1 vc4.force_hotplug=1' \
  "cmdline.txt matches golden-reference exactly (ttyS0, vc4.force_hotplug=1)"
assert_line "$WORK/boot/dietpi.txt" 'AUTO_SETUP_NET_WIFI_ENABLED=1' \
  "WiFi auto-setup enabled (dietpi-wifi.txt alone is not sufficient)"
assert_line "$WORK/boot/dietpi.txt" 'AUTO_SETUP_NET_HOSTNAME=rpi-airplay' \
  "hostname set to rpi-airplay (not the base image's generic 'DietPi')"
assert_line "$WORK/boot/dietpi.txt" 'AUTO_SETUP_AUTOMATED=1' \
  "first boot is non-interactive (flash-and-use, no wizard prompts)"
assert_line "$WORK/boot/dietpi.txt" 'SURVEY_OPTED_IN=0' \
  "survey opt-in explicitly decided (avoids an interactive first-boot prompt)"
assert_line "$WORK/boot/dietpi.txt" 'CONFIG_CHECK_DIETPI_UPDATES=0' \
  "DietPi self-update checks disabled (this pipeline controls updates, not DietPi)"
assert_line "$WORK/boot/dietpi.txt" 'CONFIG_CHECK_APT_UPDATES=0' \
  "apt update checks disabled (avoids first-boot delay + version drift)"

echo
echo "=== running the real dietpi-fs_partition_resize.service script ==="
if chroot "$WORK/root" /var/lib/dietpi/services/fs_partition_resize.sh; then
  echo "PASS: fs_partition_resize.sh completed (exit 0 -- either fully resized, or"
  echo "  cleanly scheduled DietPi's own designed intermediate reboot, both normal)"
else
  echo "FAIL: fs_partition_resize.sh exited non-zero -- a real first-boot failure"
  fail=1
fi

exit "$fail"
