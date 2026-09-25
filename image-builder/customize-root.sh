#!/bin/bash
# Customizes an extracted DietPi root directory: installs the manually
# added packages (pinned exactly via apt-packages.lock, see below), the
# vendored GStreamer runtime, the uxplay binary, and image-builder/files/
# content; strips firmware/locale/docs; resets machine-id/ssh host keys.
# Meant to run inside the shared Dockerfile tooling image.
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
#          <uxplay-debug-binary> <menu-render-binary> <log-ts-binary> \
#          <drmdump-binary> <synthetic-client-binary> <uxplay-menu-binary> \
#          <files-dir> [personal-env-file]
set -euo pipefail

work="${1:?usage: $0 <root-dir> <vendor-gstreamer-dir> <uxplay-debug-binary> <menu-render-binary> <log-ts-binary> <drmdump-binary> <synthetic-client-binary> <uxplay-menu-binary> <files-dir> [personal-env-file]}"
vendor="${2:?}"
uxplay_bin="${3:?}"
menu_render_bin="${4:?}"
log_ts_bin="${5:?}"
drmdump_bin="${6:?}"
synthetic_client_bin="${7:?}"
uxplay_menu_bin="${8:?}"
provfiles="${9:?}"
personal_env="${10:-}"

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
# the top-level package list never changes.
#
# No `apt-get update` here: it would query whatever Debian/DietPi/RPi
# Foundation currently publish, and a pinned version can vanish from that
# live index the moment upstream ships a newer point/security release
# (old versions are dropped from the published index, not just
# superseded -- the persistent apt-cache volume does NOT protect against
# this, it only caches already-downloaded .deb files, not the index apt
# resolves versions against). Instead, install directly against the
# frozen index captured once by `make refresh-apt-lists` into
# image-builder/apt-lists/ -- apt then always resolves the exact same
# pinned versions, and packages only change when that's deliberately
# re-run. Check-Valid-Until=false because that frozen index is expected
# to outlive its originally-published validity window by design (the
# same setting snapshot.debian.org itself recommends for this reason).
#
# Freezing the index only pins which VERSION resolves -- apt-get install
# still downloads the actual .deb bytes from whatever sources.list says
# at install time. archive.raspberrypi.com and dietpi.com are not durable
# enough to depend on live (2026-09-14 finding), so every apt-packages.lock
# entry that resolves from either of those (found by cross-referencing the
# lock file against each source's own frozen index -- 27 from
# archive.raspberrypi.com, 0 from dietpi.com, see
# image-builder/refresh-vendored-debs.sh) is installed from a locally
# vendored .deb (image-builder/vendored-debs/, checked into git) instead
# of by name -- apt/dpkg reads a local file's own control data directly,
# so it needs no network access and no index entry for that specific
# package at all. Debian's own live archive has the SAME durability gap
# (only keeps the latest point/security release per suite) but, unlike
# raspi/dietpi, has an official permanent fix: snapshot.debian.org serves
# every version ever published, forever, at a fixed dated URL. The
# remaining ~202 packages are `name=version` pins resolved against a
# frozen index captured FROM snapshot.debian.org at a fixed timestamp
# (DEBIAN_SNAPSHOT / DEBIAN_SECURITY_SNAPSHOT below, must match
# refresh-apt-lists.sh's own copy exactly -- both the frozen index and the
# sources.list rewritten into the chroot below have to name the same
# snapshot, or apt can't match a source's configured URI to its expected
# local index filename). One `apt-get install` call mixing local-file and
# repo-name arguments (standard apt syntax) so the whole 229-package
# closure's dependency graph resolves in one atomic pass.
DEBIAN_SNAPSHOT=20260914T142711Z
DEBIAN_SECURITY_SNAPSHOT=20260914T183713Z
lockfile="$(dirname "$0")/apt-packages.lock"
aptlists="$(dirname "$0")/apt-lists"
vendoreddebs="$(dirname "$0")/vendored-debs"
mkdir -p "$work/var/lib/apt/lists/partial"
# Only Debian's own index: archive.raspberrypi.com's and dietpi.com's are
# dead weight here now that nothing below references a package by name
# from either (vendored packages are referenced by local file path, which
# needs no index entry at all).
cp "$aptlists"/snapshot.debian.org_* "$work/var/lib/apt/lists/"
cat > "$work/etc/apt/sources.list" <<EOF
deb https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ trixie main contrib non-free non-free-firmware
deb https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ trixie-updates main contrib non-free non-free-firmware
deb https://snapshot.debian.org/archive/debian-security/${DEBIAN_SECURITY_SNAPSHOT}/ trixie-security main contrib non-free non-free-firmware
deb https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ trixie-backports main contrib non-free non-free-firmware
EOF
cp /etc/resolv.conf "$work/etc/resolv.conf"
mkdir -p "$work/tmp/vendored-debs"
cp "$vendoreddebs"/*.deb "$work/tmp/vendored-debs/"
install_args="$(python3 - "$lockfile" "$aptlists"/archive.raspberrypi.com_debian_dists_trixie_main_binary-arm64_Packages.xz <<'PYEOF'
import lzma, sys

lockfile, raspi_packages_xz = sys.argv[1], sys.argv[2]

def parse_packages(data):
    entries = {}
    name = version = fname = None
    for line in data.decode("utf-8", errors="replace").split("\n"):
        line = line.rstrip("\r")
        if line.startswith("Package: "):
            name = line[len("Package: "):]
        elif line.startswith("Version: "):
            version = line[len("Version: "):]
        elif line.startswith("Filename: "):
            fname = line[len("Filename: "):]
        elif line == "":
            if name and version:
                entries[(name, version)] = fname
            name = version = fname = None
    return entries

with open(raspi_packages_xz, "rb") as f:
    raspi_index = parse_packages(lzma.decompress(f.read()))

args = []
with open(lockfile) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, version = line.split("=", 1)
        if (name, version) in raspi_index:
            import os
            args.append("/tmp/vendored-debs/" + os.path.basename(raspi_index[(name, version)]))
        else:
            args.append(f"{name}={version}")
print(" ".join(args))
PYEOF
)"
chroot "$work" bash -c "DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Check-Valid-Until=false install -y -qq --no-install-recommends $install_args"
rm -rf "$work/tmp/vendored-debs"
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

echo "==> Installing menu-render binary"
install -m 0755 "$menu_render_bin" "$work/usr/local/bin/menu-render"

echo "==> Installing log-ts binary (uxplay.service's ExecStart wrapper/timestamper)"
install -m 0755 "$log_ts_bin" "$work/usr/local/bin/log-ts"

echo "==> Installing uxplay-menu binary (uxplay-menu.service's ExecStart)"
install -m 0755 "$uxplay_menu_bin" "$work/usr/local/bin/uxplay-menu"

echo "==> Installing the drmdump and synthetic-client diagnostic tools"
# On-demand tools, no unit and no runtime cost: drmdump dumps live DRM
# plane/CRTC state, synthetic-client drives a real RTSP/RTP session against
# uxplay (see docs/testing.md).
install -m 0755 "$drmdump_bin" "$work/usr/local/bin/drmdump"
install -m 0755 "$synthetic_client_bin" "$work/usr/local/bin/synthetic-client"

echo "==> Installing image-builder/files/ content (systemd units, tmpfiles.d, udev rule, modules-load, uxrun, zero-fb0, uxplay-menu-render, eth0-backup-ip)"
cp -a "$provfiles/etc/." "$work/etc/"
install -m 0755 "$provfiles/usr/local/bin/uxrun" "$work/usr/local/bin/uxrun"
install -m 0755 "$provfiles/usr/local/bin/zero-fb0" "$work/usr/local/bin/zero-fb0"
install -m 0755 "$provfiles/usr/local/bin/uxplay-menu-render" "$work/usr/local/bin/uxplay-menu-render"
install -m 0755 "$provfiles/usr/local/bin/eth0-backup-ip" "$work/usr/local/bin/eth0-backup-ip"

if [ -n "$personal_env" ] && [ -f "$personal_env" ]; then
  # shellcheck disable=SC1090
  . "$personal_env"
  if [ -n "${OVERSCAN_LEFT:-}" ] || [ -n "${OVERSCAN_RIGHT:-}" ] || [ -n "${OVERSCAN_TOP:-}" ] || [ -n "${OVERSCAN_BOTTOM:-}" ] || [ -n "${DISPLAY_NAME:-}" ]; then
    echo "==> Baking in overscan compensation / display name from personal.env"
    # Default sourced from the checked-in file (single source of truth for
    # "Living Room TV") rather than a second hardcoded copy here.
    default_display_name="$(. "$provfiles/etc/default/uxplay"; echo "$UXPLAY_DISPLAY_NAME")"
    cat > "$work/etc/default/uxplay" <<EOF
# Pixels to inset the rendered picture on each edge, compensating for this
# TV's own overscan/zoom cropping the outer edges of the HDMI signal. A
# value that is not an integer leaves that edge at 0, a negative one makes
# uxplay ignore all four and use the full screen; nothing here can stop
# uxplay.service from starting. Applied live -- edit and save, no restart or
# reconnect needed (uxplay-menu watches this file). Baked in at image-build
# time from personal.env.
UXPLAY_OVERSCAN_LEFT=${OVERSCAN_LEFT:-0}
UXPLAY_OVERSCAN_RIGHT=${OVERSCAN_RIGHT:-0}
UXPLAY_OVERSCAN_TOP=${OVERSCAN_TOP:-0}
UXPLAY_OVERSCAN_BOTTOM=${OVERSCAN_BOTTOM:-0}

# AirPlay device name -- shown to clients and on the idle menu screen.
# Baked in at image-build time from personal.env.
UXPLAY_DISPLAY_NAME="${DISPLAY_NAME:-$default_display_name}"
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

echo "==> Enabling uxplay.service and zero-fb0-late.service (direct symlinks --"
echo "    both units' only [Install] key is WantedBy=multi-user.target, no"
echo "    systemctl/live daemon needed). uxplay-menu.service deliberately has"
echo "    no [Install] section -- enabling it here would create a real ordering"
echo "    cycle with zero-fb0-late.service (confirmed on real hardware: systemd"
echo "    silently deletes one of the two jobs to break it, so zero-fb0-late"
echo "    never ran). It's pulled in by zero-fb0-late.service's own Wants=."
mkdir -p "$work/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/uxplay.service \
  "$work/etc/systemd/system/multi-user.target.wants/uxplay.service"
ln -sf /etc/systemd/system/zero-fb0-late.service \
  "$work/etc/systemd/system/multi-user.target.wants/zero-fb0-late.service"

echo "==> Enabling dietpi-skip-firstrun.service (without this, every"
echo "    interactive SSH login on a real boot synchronously runs the real"
echo "    dietpi-update/dietpi-software, since dietpi-firstboot.bash resets"
echo "    .install_stage to 0 on every real hardware boot regardless of"
echo "    what's baked into the image at build time)"
ln -sf /etc/systemd/system/dietpi-skip-firstrun.service \
  "$work/etc/systemd/system/multi-user.target.wants/dietpi-skip-firstrun.service"

echo "==> Enabling eth0-backup-ip.service (fixed 169.254.100.1/16 on eth0, a"
echo "    direct-cable management channel independent of WiFi and DHCP)"
ln -sf /etc/systemd/system/eth0-backup-ip.service \
  "$work/etc/systemd/system/multi-user.target.wants/eth0-backup-ip.service"

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
