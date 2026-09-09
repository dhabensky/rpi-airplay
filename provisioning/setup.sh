#!/bin/bash
# Provisions a DietPi (Debian 13 "trixie", arm64) Raspberry Pi 3B+ to run the
# uxplay_debug binary (built via ../Dockerfile.uxplay-buildtest) as a headless
# AirPlay mirror receiver: kmssink direct-to-display + v4l2h264dec hardware
# decode + ALSA HDMI audio, no X11/window system.
#
# Run as root on the target Pi. Idempotent: safe to re-run.
#
# What this does NOT do (see README.md "Known gaps" for why):
#   - does not build or install the uxplay_debug binary itself
#   - does not flash/create the base DietPi image
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Installing packages"
apt-get update
# libavahi-compat-libdnssd1: NOT optional -- UxPlay is built with
# -DUSE_DNS_SD=1 and lib/CMakeLists.txt links `airplay` directly against
# avahi-compat-libdns_sd (libdns_sd.so.1) at build time; confirmed via
# `readelf -d uxplay_debug | grep NEEDED`. Without it the binary won't even
# start (missing shared library). An earlier ldd-based check wrongly
# concluded this was unneeded -- it grepped ldd's output for the literal
# string "avahi" and missed "libdns_sd.so.1", which doesn't contain that
# substring. libavahi-client3 comes along as libavahi-compat-libdnssd1's own
# dependency.
# libplist-2.0-4: ALSO not optional, found the same way both ldd and dpkg
# missed it -- a direct link-time dependency of uxplay_debug itself (not a
# GStreamer plugin, so vendor-gstreamer-closure.sh's ldd walk never covers
# it), never dpkg-installed here either, so it was a silent untracked file.
# Only found by an actual systemd-nspawn boot test (see REBUILD-STATUS.md).
# tcpdump: genuinely useful for AirPlay protocol debugging (see PROGRESS.md's
# tcpdump-replay experiments), not incidental cruft -- kept intentionally.
apt-get install -y avahi-daemon ffmpeg gdb libavahi-compat-libdnssd1 libplist-2.0-4 tcpdump
# DietPi defaults to dropbear; this project's actual SSH usage (checked
# against the live Pi's sshd_config + auth log) is plain password auth and
# remote command execution only -- no sftp/scp, no X11 forwarding, no
# ProxyJump, no key-based auth ever used -- so dropbear fully covers it.
# openssh-server was installed once as a 'fix' for a Tier A diff without
# checking whether it was actually needed; reverted back to DietPi's default.
# Install dropbear BEFORE purging openssh -- if this script runs over an
# existing openssh-only SSH session (as it would on the live Pi today),
# purging openssh first would cut off remote access before dropbear is
# there to take over.
apt-get install -y dropbear dropbear-bin
apt-get purge -y openssh-server openssh-client openssh-sftp-server 2>/dev/null || true
apt-get autoremove -y

echo "==> Vendoring GStreamer runtime (not available as trixie arm64 packages"
echo "    without pulling gstreamer1.0-plugins-good/bad's full X11/Wayland/dbus/"
echo "    PulseAudio closure -- see vendor/gstreamer-1.0-arm64-trixie/MANIFEST.md)"
# plugins/ -> GStreamer's own plugin-scanner path, EXCEPT gst-plugin-scanner
# itself, which lives one level up (see MANIFEST.md's "don't flatten"
# note -- a prior manual extraction only ever did this half, silently
# missing libs/ below, which happened to already be on the live Pi from an
# undocumented earlier step and masked the gap).
install -d /usr/lib/aarch64-linux-gnu/gstreamer-1.0
install -m 0644 -t /usr/lib/aarch64-linux-gnu/gstreamer-1.0 \
  ../vendor/gstreamer-1.0-arm64-trixie/plugins/*.so
install -d /usr/lib/aarch64-linux-gnu/gstreamer1.0/gstreamer-1.0
install -m 0755 ../vendor/gstreamer-1.0-arm64-trixie/plugins/gst-plugin-scanner \
  /usr/lib/aarch64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner
# libs/ -> general shared libraries the plugins link against, installed
# directly under the arch lib dir (not the plugin directory).
install -d /usr/lib/aarch64-linux-gnu
install -m 0644 -t /usr/lib/aarch64-linux-gnu \
  ../vendor/gstreamer-1.0-arm64-trixie/libs/*
ldconfig

echo "==> Enabling persistent journald logging (DietPi default is volatile --"
echo "    /run tmpfs only, wiped on power-off)"
install -d -m 2755 -o root -g systemd-journal /var/log/journal

echo "==> Enabling the bcm2835 hardware H.264 decoder (DietPi blacklists it by default)"
rm -f /etc/modprobe.d/dietpi-disable_rpi_codec.conf
install -m 0644 files/etc/modules-load.d/bcm2835-codec.conf /etc/modules-load.d/bcm2835-codec.conf
install -m 0644 files/etc/udev/rules.d/99-bcm2835-codec.rules /etc/udev/rules.d/99-bcm2835-codec.rules
modprobe bcm2835-codec || echo "    (modprobe failed -- reboot required to load it for the first time)"

echo "==> Masking getty on tty1 (stops it fighting uxplay for console/DRM master)"
systemctl mask getty@tty1.service

echo "==> Creating the uxplay service user"
if ! id uxplay >/dev/null 2>&1; then
  useradd -r -M -s /usr/sbin/nologin -G audio,video,render,input uxplay
fi
install -d -o uxplay -g uxplay -m 0755 /home/uxplay

echo "==> Installing the systemd unit"
install -m 0644 files/etc/systemd/system/uxplay.service /etc/systemd/system/uxplay.service
systemctl daemon-reload
systemctl enable uxplay.service

echo "==> Installing the uxrun A/V-sync tuning helper"
install -m 0755 files/usr/local/bin/uxrun /usr/local/bin/uxrun

cat <<'EOF'

==> Done. Remaining manual steps:
    1. Build the receiver binary: see ../README.md "Building the uxplay_debug binary".
    2. Copy it to /usr/local/bin/uxplay_debug on this Pi (matches the ExecStart
       in files/etc/systemd/system/uxplay.service).
    3. If this is the first time bcm2835-codec was loaded, reboot once.
    4. systemctl start uxplay.service
EOF
