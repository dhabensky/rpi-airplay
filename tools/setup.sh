#!/bin/bash
# Provisions a DietPi (Debian 13 "trixie", arm64) Raspberry Pi 3B+ to run the
# uxplay_debug binary (built via ../tools/build-uxplay.sh) as a headless
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
# openssh, not dropbear (reverted a second time) -- dropbear has no
# sftp/scp support at all, which forces every file deploy this project
# actually needs (pushing a rebuilt uxplay_debug binary, etc.) through an
# awkward `ssh ... 'cat > file' < localfile` workaround instead of `scp`.
# Install openssh BEFORE purging dropbear -- if this script runs over an
# existing dropbear-only SSH session, purging dropbear first would cut off
# remote access before openssh is there to take over.
apt-get install -y openssh-server openssh-client openssh-sftp-server
# Root password login, without which installing openssh-server locks the
# device out the moment dropbear is purged below (getty@tty1 is masked, so
# there is no console fallback either) -- see the installed file's own
# header for the rest.
install -d /etc/ssh/sshd_config.d
install -m 0644 ../image-builder/files/etc/ssh/sshd_config.d/root-password-login.conf \
  /etc/ssh/sshd_config.d/root-password-login.conf
systemctl reload ssh 2>/dev/null || true
apt-get purge -y dropbear dropbear-bin 2>/dev/null || true
apt-get autoremove -y

echo "==> Vendoring GStreamer runtime (not available as trixie arm64 packages"
echo "    without pulling gstreamer1.0-plugins-good/bad's full X11/Wayland/dbus/"
echo "    PulseAudio closure -- see build/vendor-gstreamer/MANIFEST.md)"
# Requires ../build/vendor-gstreamer/ to already be present -- run
# `make vendor-gstreamer` on a Docker-capable machine (the Mac, matching
# every other build step in this project -- nothing is ever built on the
# Pi itself) and copy build/vendor-gstreamer/ alongside this script before
# running it here.
#
# plugins/ -> GStreamer's own plugin-scanner path, EXCEPT gst-plugin-scanner
# itself, which lives one level up (see MANIFEST.md's "don't flatten"
# note -- a prior manual extraction only ever did this half, silently
# missing libs/ below, which happened to already be on the live Pi from an
# undocumented earlier step and masked the gap).
install -d /usr/lib/aarch64-linux-gnu/gstreamer-1.0
install -m 0644 -t /usr/lib/aarch64-linux-gnu/gstreamer-1.0 \
  ../build/vendor-gstreamer/plugins/*.so
install -d /usr/lib/aarch64-linux-gnu/gstreamer1.0/gstreamer-1.0
install -m 0755 ../build/vendor-gstreamer/plugins/gst-plugin-scanner \
  /usr/lib/aarch64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner
# libs/ -> general shared libraries the plugins link against, installed
# directly under the arch lib dir (not the plugin directory).
install -d /usr/lib/aarch64-linux-gnu
install -m 0644 -t /usr/lib/aarch64-linux-gnu \
  ../build/vendor-gstreamer/libs/*
ldconfig

echo "==> Enabling persistent journald logging with rate limiting off (uxplay"
echo "    logs to the journal, so it has to survive the reboot after a bug)."
echo "    DietPi's RAMlog tmpfs over /var/log would make Storage=persistent a"
echo "    no-op, so it goes, along with the unit that repopulates it."
install -d /etc/systemd/journald.conf.d
install -m 0644 ../image-builder/files/etc/systemd/journald.conf.d/uxplay.conf \
  /etc/systemd/journald.conf.d/uxplay.conf
sed -i '\|^tmpfs /var/log tmpfs |d' /etc/fstab
systemctl disable dietpi-ramlog.service 2>/dev/null || true
# journald creates /var/log/journal itself once that tmpfs is gone, which
# needs the reboot below -- unmounting a live /var/log here would only hide
# it from processes that already hold fds in it.

echo "==> Enabling the bcm2835 hardware H.264 decoder (DietPi blacklists it by default)"
rm -f /etc/modprobe.d/dietpi-disable_rpi_codec.conf
install -m 0644 ../image-builder/files/etc/modules-load.d/bcm2835-codec.conf /etc/modules-load.d/bcm2835-codec.conf
install -m 0644 ../image-builder/files/etc/udev/rules.d/99-bcm2835-codec.rules /etc/udev/rules.d/99-bcm2835-codec.rules
modprobe bcm2835-codec || echo "    (modprobe failed -- reboot required to load it for the first time)"

echo "==> Masking getty on tty1 (stops it fighting uxplay for console/DRM master)"
systemctl mask getty@tty1.service

echo "==> Quieting the console: the boot log still renders, but past that only"
echo "    a panic may repaint /dev/fb0 over the idle menu or a session"
install -m 0644 ../image-builder/files/etc/sysctl.d/99-quiet-console.conf \
  /etc/sysctl.d/99-quiet-console.conf
systemctl restart systemd-sysctl.service

echo "==> Creating the uxplay service user"
if ! id uxplay >/dev/null 2>&1; then
  useradd -r -M -s /usr/sbin/nologin -G audio,video,render,input uxplay
fi
install -d -o uxplay -g uxplay -m 0755 /home/uxplay

echo "==> Installing the systemd unit"
install -m 0644 ../image-builder/files/etc/systemd/system/uxplay.service /etc/systemd/system/uxplay.service

echo "==> Installing the DietPi first-run-wizard skip (without this, every"
echo "    interactive SSH login synchronously runs the real dietpi-update/"
echo "    dietpi-software, since dietpi-firstboot.bash resets .install_stage"
echo "    to 0 on every real hardware boot regardless of what's baked into"
echo "    the image)"
install -m 0644 ../image-builder/files/etc/systemd/system/dietpi-skip-firstrun.service /etc/systemd/system/dietpi-skip-firstrun.service
systemctl daemon-reload
systemctl enable --now dietpi-skip-firstrun.service

echo "==> Installing the overscan config (only if not already present -- this"
echo "    file is meant to be hand-tuned live on a running device; re-running"
echo "    this script must not clobber someone's already-tuned values back"
echo "    to all-zero)"
if [ ! -f /etc/default/uxplay ]; then
  install -d /etc/default
  install -m 0644 ../image-builder/files/etc/default/uxplay /etc/default/uxplay
fi
systemctl enable uxplay.service

echo "==> Installing the fbcon-blanking ExecStartPre helper"
install -m 0755 ../image-builder/files/usr/local/bin/zero-fb0 /usr/local/bin/zero-fb0

echo "==> Installing the idle-menu supervisor (repaints on session end, on a"
echo "    /etc/default/uxplay edit and every 5 minutes, and pushes edited"
echo "    overscan values through uxplay's -ofifo) plus uxplay's event FIFO"
install -m 0644 ../image-builder/files/etc/tmpfiles.d/uxplay.conf /etc/tmpfiles.d/uxplay.conf
systemd-tmpfiles --create /etc/tmpfiles.d/uxplay.conf
install -m 0755 ../image-builder/files/usr/local/bin/uxplay-menu-render /usr/local/bin/uxplay-menu-render
install -m 0644 ../image-builder/files/etc/systemd/system/uxplay-menu.service /etc/systemd/system/uxplay-menu.service
install -m 0644 ../image-builder/files/etc/systemd/system/zero-fb0-late.service /etc/systemd/system/zero-fb0-late.service
systemctl daemon-reload
# --now so the daemon exists before the next reboot; zero-fb0 also clears the
# HDMI console now. Until step 2 installs /usr/local/bin/uxplay-menu the unit
# restarts every 3s forever (systemd's 5-per-10s default can't trip at 3s).
systemctl enable --now zero-fb0-late.service

echo "==> Installing the uxrun A/V-sync tuning helper"
install -m 0755 ../image-builder/files/usr/local/bin/uxrun /usr/local/bin/uxrun

cat <<'EOF'

==> Done. Remaining manual steps:
    1. Build the receiver binary: see ../README.md "Building the uxplay_debug binary".
    2. Copy it to /usr/local/bin/uxplay_debug on this Pi, plus
       `make uxplay-menu`'s build/bin/uxplay-menu to /usr/local/bin/uxplay-menu
       (uxplay-menu.service's ExecStart), plus `make menu-render`'s
       build/bin/menu-render to /usr/local/bin/menu-render.
    3. Reboot once: that is what moves /var/log off DietPi's RAMlog tmpfs,
       and bcm2835-codec may also be loading for the first time.
    4. systemctl start uxplay.service
EOF
