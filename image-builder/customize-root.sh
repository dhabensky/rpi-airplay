#!/bin/bash
# Customizes an extracted DietPi root directory: installs the 3 manual
# packages, the vendored GStreamer runtime, the uxplay binary, and
# provisioning/files/ content; strips firmware/locale/docs; resets
# machine-id/ssh host keys. Meant to run inside the image-builder container
# (Dockerfile.image-builder).
#
# <root-dir> must be a Docker named volume mount, NOT a macOS host
# bind-mount (`-v $HOST_PATH:/x`): the virtiofs bridge macOS Docker/colima
# uses for host bind-mounts silently discards non-root chown() calls (the
# daemon performing the actual filesystem op on the Mac side runs as your
# regular unprivileged macOS user, which can't chown to arbitrary UIDs on
# the real host filesystem) -- confirmed empirically, including a bare
# `chown` on such a path returning success but not persisting. Every
# non-root ownership set in this script (uxplay:uxplay, root:systemd-journal)
# would be silently flattened to root:root by the time build-image.sh reads
# it back. Named volumes are backed by the colima VM's own filesystem, not
# shared via virtiofs, so chroot/chown work normally there -- verified via
# `debugfs rdump` correctly preserving /etc/shadow's root:shadow ownership
# when extracted to container-local storage vs. losing it on a bind mount.
# (This also means this directory generally isn't `ls`-able directly from
# the host anymore -- inspect it via `docker run -v <volume>:/x ... find/stat`.)
#
# Usage: image-builder/customize-root.sh <root-dir> <vendor-gstreamer-dir> \
#          <uxplay-debug-binary> <provisioning-files-dir>
set -euo pipefail

work="${1:?usage: $0 <root-dir> <vendor-gstreamer-dir> <uxplay-debug-binary> <provisioning-files-dir>}"
vendor="${2:?}"
uxplay_bin="${3:?}"
provfiles="${4:?}"

echo "==> Installing packages (avahi-daemon, ffmpeg, gdb, libavahi-compat-libdnssd1, libplist-2.0-4, tcpdump)"
# libavahi-compat-libdnssd1: NOT optional. lib/CMakeLists.txt links `airplay`
# directly against avahi-compat-libdns_sd (libdns_sd.so.1) at build time
# (-DUSE_DNS_SD=1); confirmed via `readelf -d uxplay_debug | grep NEEDED` --
# it's a real DT_NEEDED entry, so uxplay_debug won't even start without it.
# An earlier ldd-based check wrongly called this unneeded cruft -- it grepped
# ldd's output for the literal string "avahi" and missed "libdns_sd.so.1",
# which doesn't contain that substring. libavahi-client3 comes along
# transitively as libavahi-compat-libdnssd1's own dependency.
# libplist-2.0-4: ALSO not optional and found the same way ldd/dpkg both
# missed it -- it's a direct link-time dependency of uxplay_debug itself
# (not a GStreamer plugin, so tools/vendor-gstreamer-closure.sh's ldd walk,
# which only starts from plugin .so files, never covers it), and it was
# never dpkg-installed on the live Pi either (no Tier A diff), so this was a
# silent, untracked manual file placement -- invisible in Tier B's own
# output too, since a missing file just inflates the "golden-only paths"
# aggregate count without ever being listed individually. Only found by
# actually trying to run the binary (systemd-nspawn boot test, see
# REBUILD-STATUS.md) -- "error while loading shared libraries:
# libplist-2.0.so.4: cannot open shared object file".
# tcpdump: genuinely useful for AirPlay protocol debugging (see PROGRESS.md's
# tcpdump-replay experiments), not incidental cruft from an old session --
# kept intentionally.
# openssh, not dropbear (reverted back a second time -- dropbear has no
# sftp/scp support at all, which made every file deploy this project needs
# (pushing a rebuilt uxplay_debug binary, etc.) go through an awkward
# `ssh ... 'cat > file' < localfile` workaround instead of a normal `scp`.
# The earlier "dropbear fully covers this project's actual usage" reasoning
# was true only in the narrow sense that nothing had *needed* scp yet --
# once real iteration started needing to push binaries repeatedly, that
# turned out to matter in practice.
# Verified empirically: these packages' postinst scripts run cleanly with
# no /proc mounted (just the standard, harmless "invoke-rc.d: could not
# determine current runlevel" chroot warning, exit 0) -- so no mount(),
# no CAP_SYS_ADMIN, no privilege needed at all for this step.
cp /etc/resolv.conf "$work/etc/resolv.conf"
chroot "$work" bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends avahi-daemon ffmpeg gdb libavahi-compat-libdnssd1 libplist-2.0-4 tcpdump openssh-server'
chroot "$work" bash -c 'DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq dropbear dropbear-bin 2>/dev/null || true'
chroot "$work" bash -c 'apt-get autoremove -y -qq'
chroot "$work" bash -c 'apt-get clean'
rm -rf "$work/var/lib/apt/lists/"*

echo "==> Allowing root password login over SSH"
# Debian's OpenSSH ships with PermitRootLogin=prohibit-password by default
# (root can only log in via key, never password) -- this project has only
# ever used root/password auth (no keys), and this device's console login
# (getty@tty1) is deliberately masked below, with no other way in if this
# is missed. Learned this the hard way: installing openssh-server without
# this override locked out the live Pi entirely (no console, no working
# SSH) until fixed by writing this exact file directly into the SD card's
# ext4 image offline via `debugfs -w`.
install -d "$work/etc/ssh/sshd_config.d"
cat > "$work/etc/ssh/sshd_config.d/root-password-login.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF

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

echo "==> Enabling persistent journald logging (DietPi default is volatile --"
echo "    /run tmpfs only, wiped on power-off -- learned the hard way when a"
echo "    first-boot's console errors turned out to be unrecoverable from the"
echo "    card afterwards)"
# chroot for ownership: "systemd-journal" only resolves against the
# target's /etc/group, not the outer container's (same class of bug as the
# uxplay user above).
chroot "$work" install -d -m 2755 -o root -g systemd-journal /var/log/journal

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

echo "Customization complete: $work"
