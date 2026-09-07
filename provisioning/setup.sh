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
apt-get install -y avahi-daemon ffmpeg gdb

echo "==> Vendoring GStreamer runtime plugins (not available as trixie arm64 packages"
echo "    without pulling gstreamer1.0-plugins-good/bad's full X11/Wayland/dbus/"
echo "    PulseAudio closure -- see README.md)"
install -d /usr/lib/aarch64-linux-gnu/gstreamer-1.0
install -m 0644 -t /usr/lib/aarch64-linux-gnu/gstreamer-1.0 \
  ../vendor/gstreamer-1.0-arm64-trixie/plugins/*.so
install -d /usr/lib/aarch64-linux-gnu/gstreamer1.0/gstreamer-1.0
install -m 0755 ../vendor/gstreamer-1.0-arm64-trixie/gst-plugin-scanner \
  /usr/lib/aarch64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner
install -m 0644 ../vendor/gstreamer-1.0-arm64-trixie/liborc-0.4.so.0 \
  /usr/lib/aarch64-linux-gnu/liborc-0.4.so.0
ldconfig

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

cat <<'EOF'

==> Done. Remaining manual steps:
    1. Build the receiver binary: see ../README.md "Building the uxplay_debug binary".
    2. Copy it to /usr/local/bin/uxplay_debug on this Pi (matches the ExecStart
       in files/etc/systemd/system/uxplay.service).
    3. If this is the first time bcm2835-codec was loaded, reboot once.
    4. systemctl start uxplay.service
EOF
