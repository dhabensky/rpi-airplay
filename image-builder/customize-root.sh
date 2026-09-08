#!/bin/bash
# Customizes an extracted DietPi root directory: installs the 3 manual
# packages, the vendored GStreamer runtime, the uxplay binary, and
# provisioning/files/ content; strips firmware/locale/docs; resets
# machine-id/ssh host keys. Meant to run inside the image-builder container
# (Dockerfile.image-builder).
#
# IMPORTANT: chroot-ing into a directory reached via a macOS Docker Desktop
# bind-mount (`-v $HOST_PATH:/x`) fails opaquely ("No such file or
# directory" on a binary that demonstrably exists) -- verified empirically,
# not a capability/privilege issue (CAP_SYS_CHROOT is present; chrooting
# into the exact same content copied into the container's own filesystem
# works fine). So: copy the input root dir into container-local storage
# first, do all chroot work there, then copy the result back out. Costs an
# extra copy of the rootfs (~a few hundred MB) but sidesteps the issue
# entirely regardless of whether the caller's paths are bind-mounted.
#
# Usage: image-builder/customize-root.sh <root-dir> <vendor-gstreamer-dir> \
#          <uxplay-debug-binary> <provisioning-files-dir>
set -euo pipefail

rootdir_in="${1:?usage: $0 <root-dir> <vendor-gstreamer-dir> <uxplay-debug-binary> <provisioning-files-dir>}"
vendor="${2:?}"
uxplay_bin="${3:?}"
provfiles="${4:?}"

work=/tmp/customize-root-work
rm -rf "$work"
mkdir -p "$work"
echo "==> Copying root dir into container-local storage (avoids the chroot/bind-mount issue)"
cp -a "$rootdir_in/." "$work/"

echo "==> Installing packages (avahi-daemon, ffmpeg, gdb, openssh-server --"
echo "    found via 'make verify' Tier A, not originally in this script:"
echo "    the live Pi runs OpenSSH, not DietPi's default dropbear -- that's"
echo "    how this whole project has been managed over SSH throughout)"
# Verified empirically: these packages' postinst scripts run cleanly with
# no /proc mounted (just the standard, harmless "invoke-rc.d: could not
# determine current runlevel" chroot warning, exit 0) -- so no mount(),
# no CAP_SYS_ADMIN, no privilege needed at all for this step.
cp /etc/resolv.conf "$work/etc/resolv.conf"
chroot "$work" bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends avahi-daemon ffmpeg gdb openssh-server'
chroot "$work" bash -c 'DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq dropbear dropbear-bin 2>/dev/null || true'
chroot "$work" bash -c 'apt-get autoremove -y -qq'
chroot "$work" bash -c 'apt-get clean'
rm -rf "$work/var/lib/apt/lists/"*

echo "==> Installing vendored GStreamer runtime"
install -d "$work/usr/lib/aarch64-linux-gnu/gstreamer-1.0"
install -m 0644 -t "$work/usr/lib/aarch64-linux-gnu/gstreamer-1.0" "$vendor/plugins/"*.so
install -d "$work/usr/lib/aarch64-linux-gnu/gstreamer1.0/gstreamer-1.0"
install -m 0755 "$vendor/plugins/gst-plugin-scanner" \
  "$work/usr/lib/aarch64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner"
install -m 0644 -t "$work/usr/lib/aarch64-linux-gnu" "$vendor/libs/"*

echo "==> Installing uxplay_debug binary"
install -m 0755 "$uxplay_bin" "$work/usr/local/bin/uxplay_debug"

echo "==> Installing provisioning/files/ content (systemd unit, udev rule, modules-load, uxrun)"
cp -a "$provfiles/etc/." "$work/etc/"
install -m 0755 "$provfiles/usr/local/bin/uxrun" "$work/usr/local/bin/uxrun"

echo "==> Un-blacklisting the bcm2835 hardware H.264 decoder"
rm -f "$work/etc/modprobe.d/dietpi-disable_rpi_codec.conf"

echo "==> Masking getty on tty1"
ln -sf /dev/null "$work/etc/systemd/system/getty@tty1.service"

echo "==> Creating the uxplay system user"
# render/input normally exist already on a real RPi OS image (created by
# udev/systemd-udevd for DRM/input device permissions) -- groupadd -f makes
# this safe regardless, rather than assuming that's true on every variant.
for g in audio video render input; do chroot "$work" groupadd -f "$g"; done
chroot "$work" useradd -r -M -s /usr/sbin/nologin -G audio,video,render,input uxplay
# chroot for ownership: "uxplay" only exists in the target's /etc/passwd,
# not the outer container's -- a host-side `install -o uxplay` can't
# resolve it.
chroot "$work" install -d -o uxplay -g uxplay -m 0755 /home/uxplay

echo "==> Enabling uxplay.service (direct symlink -- the unit's only [Install]"
echo "    key is WantedBy=multi-user.target, no systemctl/live daemon needed)"
mkdir -p "$work/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/uxplay.service \
  "$work/etc/systemd/system/multi-user.target.wants/uxplay.service"

echo "==> Trimming firmware to brcm/cypress (this Pi's actual WiFi/BT chip)"
if [ -d "$work/usr/lib/firmware" ]; then
  find "$work/usr/lib/firmware" -mindepth 1 -maxdepth 1 \
    -not -name brcm -not -name cypress -exec rm -rf {} +
fi

echo "==> Stripping docs/man/non-English locales"
rm -rf "$work/usr/share/doc"/* "$work/usr/share/man"/*
if [ -d "$work/usr/share/locale" ]; then
  find "$work/usr/share/locale" -mindepth 1 -maxdepth 1 -not -name 'en*' -exec rm -rf {} +
fi

echo "==> Resetting machine-id / SSH host keys (regenerate on first real boot --"
echo "    verify this doesn't fight DietPi's own first-boot identity regen)"
: > "$work/etc/machine-id" || true
rm -f "$work/etc/ssh/ssh_host_"*_key*

echo "==> Copying customized root back out"
rm -rf "${rootdir_in:?}"/*
cp -a "$work/." "$rootdir_in/"
rm -rf "$work"
echo "Customization complete: $rootdir_in"
