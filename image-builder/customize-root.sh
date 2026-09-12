#!/bin/bash
# Customizes an extracted DietPi root directory: installs the manually
# added packages (pinned exactly via apt-packages.lock, see below), the
# vendored GStreamer runtime, the uxplay binary, and provisioning/files/
# content; strips firmware/locale/docs; resets machine-id/ssh host keys.
# Meant to run inside the image-builder container (Dockerfile.image-builder).
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
#          <uxplay-debug-binary> <provisioning-files-dir> [personal-env-file]
set -euo pipefail

work="${1:?usage: $0 <root-dir> <vendor-gstreamer-dir> <uxplay-debug-binary> <provisioning-files-dir> [personal-env-file]}"
vendor="${2:?}"
uxplay_bin="${3:?}"
provfiles="${4:?}"
personal_env="${5:-}"

# The Makefile mounts a persistent named volume directly at
# $work/var/cache/apt/archives (via an extra `-v` flag on the `docker run`
# that invokes this script) so re-downloading unchanged .deb files isn't
# paid on every single rebuild -- root-dir itself is always extracted
# fresh from the pristine base image (see the Makefile's `docker volume rm
# -f` at the top of build/rpi-airplay.img's recipe), so without this, apt
# has nothing to reuse across builds even when the package list hasn't
# changed. This was the single largest per-build cost measured (~2 of the
# ~5 minute image-assembly pipeline). Mounting it this way (Docker's own
# `-v`, onto a path already inside the volume this script receives) needs
# no extra capability -- unlike an in-script `mount --bind`, which would
# need CAP_SYS_ADMIN (not in Docker's default capability set, unlike
# CAP_SYS_CHROOT which this whole pipeline otherwise relies on) and would
# be a real, unwanted departure from this project's zero-privilege-
# container design. Detect whether it's actually mounted (vs. a plain
# subdirectory of the ephemeral root-dir volume) so the `apt-get clean`
# step below knows whether to skip cleaning it.
apt_cache_mounted=0
mountpoint -q "$work/var/cache/apt/archives" 2>/dev/null && apt_cache_mounted=1

echo "==> Installing packages, pinned to image-builder/apt-packages.lock (avahi-daemon, ffmpeg, gdb, libavahi-compat-libdnssd1, libplist-2.0-4, tcpdump, openssh-server + their full transitive closure)"
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
#
# Every package below (not just these 7 named ones) is pinned to an exact
# version via image-builder/apt-packages.lock -- without pinning the full
# ~220-package transitive closure too, apt-get would silently resolve
# whatever's currently newest in trixie for every unpinned dependency on
# every build, making the image non-reproducible over time even though
# the top-level package list never changes. Pins are validated against
# whatever trixie mirror `apt-get update` currently sees, not a frozen
# snapshot -- see that file's header for the tradeoff (a version can in
# principle age out of the live archive; the persistent apt-cache volume
# shields same-machine rebuilds from that even then, but a fresh machine
# would need the lock file regenerated) and how to regenerate it.
lockfile="$(dirname "$0")/apt-packages.lock"
pinned_packages="$(grep -v '^#' "$lockfile" | grep -v '^$' | tr '\n' ' ')"
cp /etc/resolv.conf "$work/etc/resolv.conf"
chroot "$work" bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $pinned_packages"
chroot "$work" bash -c 'DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq dropbear dropbear-bin 2>/dev/null || true'
chroot "$work" bash -c 'apt-get autoremove -y -qq'
if [ "$apt_cache_mounted" = 0 ]; then
  # No persistent cache volume mounted here (e.g. this script run directly,
  # outside the Makefile) -- clean normally so downloaded .debs don't bloat
  # the shipped image.
  chroot "$work" bash -c 'apt-get clean'
else
  # Do NOT `apt-get clean` here -- /var/cache/apt/archives is currently the
  # persistent cache *volume* itself (mounted by the Makefile's `docker run
  # -v`, a separate volume from root-dir's own storage); cleaning would
  # delete the very .debs future builds are meant to reuse. This directory
  # never ends up in the shipped image regardless: build-image.sh's later
  # `mkfs.ext4 -d` reads root-dir's OWN volume, whose copy of this path was
  # simply shadowed (never written to) while the cache volume was mounted
  # over it here -- so it's still empty there, no extra step needed.
  :
fi
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

echo "==> Fixing sshd host-key generation to survive DietPi's first-boot resize+reboot"
# sshd-keygen.service (generates the host keys sshd needs to bind at all)
# ships with ConditionFirstBoot=yes -- a strict systemd one-shot condition
# tied to /etc/machine-id being empty at that exact kernel boot. DietPi's
# own first-boot flow does a filesystem resize + automatic reboot before
# most services (including this one) ever get a chance to run; by the
# *second* kernel boot systemd has already written a real machine-id
# (persisted across the reboot), so ConditionFirstBoot=yes evaluates false
# forever -- host keys never get generated, sshd can never bind, and every
# connection gets refused permanently. Confirmed empirically: a freshly
# flashed, otherwise-working image never brought up sshd at all. Override
# the trigger to be based on whether the keys actually exist instead of a
# one-shot boot counter, so it fires correctly no matter which kernel boot
# ssh.service first actually starts on.
install -d "$work/etc/systemd/system/sshd-keygen.service.d"
cat > "$work/etc/systemd/system/sshd-keygen.service.d/override.conf" <<'EOF'
[Unit]
ConditionFirstBoot=
ConditionPathExists=!/etc/ssh/ssh_host_rsa_key
EOF

echo "==> Marking DietPi's first-run setup as already complete"
# /boot/dietpi/.install_stage (part of the root ext4 partition, NOT the
# FAT32 firmware boot partition despite the "/boot" path) tracks DietPi's
# own first-run flow: -1 = not yet run, 1 = dietpi-update finished, 2 =
# dietpi-software finished (see /boot/dietpi/dietpi-login's own checks at
# that exact value). It ships at -1 in the base image, and normally only
# advances via DietPi's own dietpi-firstrun-setup service actually
# executing at real boot time -- which never happens in THIS pipeline's
# offline chroot build (no live systemd here to run it). Left at -1,
# dietpi-login (sourced on every interactive login) reruns the entire
# apt-update/dietpi-software first-run wizard on every single SSH login,
# forever -- confirmed on the real device. This project's own build
# pipeline already IS the "first-run setup" (packages, users, config all
# baked in at build time, matching the project's whole design), so just
# mark it done directly rather than let DietPi redundantly redo its own
# version of that at login time.
echo 2 > "$work/boot/dietpi/.install_stage"

echo "==> Installing vendored GStreamer runtime"
install -d "$work/usr/lib/aarch64-linux-gnu/gstreamer-1.0"
install -m 0644 -t "$work/usr/lib/aarch64-linux-gnu/gstreamer-1.0" "$vendor/plugins/"*.so
install -d "$work/usr/lib/aarch64-linux-gnu/gstreamer1.0/gstreamer-1.0"
install -m 0755 "$vendor/plugins/gst-plugin-scanner" \
  "$work/usr/lib/aarch64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner"
install -m 0644 -t "$work/usr/lib/aarch64-linux-gnu" "$vendor/libs/"*

echo "==> Installing uxplay_debug binary"
install -m 0755 "$uxplay_bin" "$work/usr/local/bin/uxplay_debug"

echo "==> Installing provisioning/files/ content (systemd unit, udev rule, modules-load, uxrun, zero-fb0)"
cp -a "$provfiles/etc/." "$work/etc/"
install -m 0755 "$provfiles/usr/local/bin/uxrun" "$work/usr/local/bin/uxrun"
# zero-fb0: 2026-09-12 fix, was previously only ever deployed ad hoc over SSH,
# never actually added here -- a fresh image build would have silently
# shipped without it.
install -m 0755 "$provfiles/usr/local/bin/zero-fb0" "$work/usr/local/bin/zero-fb0"

if [ -n "$personal_env" ] && [ -f "$personal_env" ]; then
  # shellcheck disable=SC1090
  . "$personal_env"
  if [ -n "${OVERSCAN_LEFT:-}" ] || [ -n "${OVERSCAN_RIGHT:-}" ] || [ -n "${OVERSCAN_TOP:-}" ] || [ -n "${OVERSCAN_BOTTOM:-}" ]; then
    echo "==> Baking in overscan compensation from personal.env"
    cat > "$work/etc/default/uxplay" <<EOF
# Pixels to inset the rendered picture on each edge, compensating for this
# TV's own overscan/zoom cropping the outer edges of the HDMI signal.
# Applied live -- edit and save, no restart or reconnect needed (uxplay
# watches this file). Baked in at image-build time from personal.env; see
# PROGRESS.md's 2026-09-12 entry for how to measure your own TV's crop.
UXPLAY_OVERSCAN_LEFT=${OVERSCAN_LEFT:-0}
UXPLAY_OVERSCAN_RIGHT=${OVERSCAN_RIGHT:-0}
UXPLAY_OVERSCAN_TOP=${OVERSCAN_TOP:-0}
UXPLAY_OVERSCAN_BOTTOM=${OVERSCAN_BOTTOM:-0}
EOF
  fi
fi

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

echo "==> Enabling dietpi-skip-firstrun.service (2026-09-12 fix -- without this,"
echo "    every interactive SSH login on a real boot synchronously runs the"
echo "    real dietpi-update/dietpi-software, since dietpi-firstboot.bash"
echo "    resets .install_stage to 0 on every real hardware boot regardless"
echo "    of what's baked into the image at build time; see PROGRESS.md's"
echo "    2026-09-12 entry for the full trace)"
ln -sf /etc/systemd/system/dietpi-skip-firstrun.service \
  "$work/etc/systemd/system/multi-user.target.wants/dietpi-skip-firstrun.service"

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
