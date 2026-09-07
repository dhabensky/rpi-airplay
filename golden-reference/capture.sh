#!/bin/bash
# Captures a comparison snapshot from the live Pi: package manifest,
# file-tree content hashes (minus EXCLUDE-LIST.md's volatile paths), and
# verbatim copies of the config files also mirrored in provisioning/files/
# (as a drift check against what we think is deployed).
#
# Run from the Mac (matches every other Pi interaction in this project --
# no SSH/build tooling is expected on the Pi itself).
#
# Usage: golden-reference/capture.sh [user@host]  (default: root@192.168.1.34)
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-root@192.168.1.34}"
DATE=$(date +%Y-%m-%d)
OUT="golden-reference/snapshots/$DATE"
mkdir -p "$OUT"

# No SSH key is provisioned on the Pi (password auth only, per README) --
# use sshpass if SSHPASS is set (matches every other Pi interaction in this
# project), otherwise fall back to plain ssh in case a key IS set up.
if [ -n "${SSHPASS:-}" ]; then
  ssh_cmd() { sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$TARGET" "$@"; }
else
  ssh_cmd() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$TARGET" "$@"; }
fi

echo "==> Package manifest"
ssh_cmd 'dpkg --get-selections' > "$OUT/package-manifest.txt"
ssh_cmd 'apt-mark showmanual' > "$OUT/package-manifest-manual.txt"

echo "==> Building find exclude args from EXCLUDE-LIST.md"
# Each pattern must stay single-quoted in the assembled remote command --
# the whole thing is sent to ssh as one string and re-parsed by the
# remote's shell, so an unquoted "*" (e.g. ssh_host_*_key*) gets glob-
# expanded by that shell against the Pi's filesystem before find ever
# sees it, corrupting the -path argument entirely.
exclude_str=""
while IFS= read -r pattern; do
  [ -z "$pattern" ] && continue
  exclude_str="$exclude_str -not -path '$pattern'"
done < <(sed -n '/^```$/,/^```$/p' golden-reference/EXCLUDE-LIST.md | sed '1d;$d')

echo "==> File-tree content manifest (this can take a minute)"
remote_find="find / -xdev -type f $exclude_str -exec sha256sum {} + 2>/dev/null | sort -k2"
ssh_cmd "$remote_find" > "$OUT/filetree-manifest.sha256"
remote_find_boot="find /boot/firmware -type f -exec sha256sum {} + 2>/dev/null | sort -k2"
ssh_cmd "$remote_find_boot" > "$OUT/filetree-manifest-boot.sha256"

echo "==> Config file drift check (verbatim copies, compare against provisioning/files/)"
mkdir -p "$OUT/config"
ssh_cmd 'cat /etc/systemd/system/uxplay.service' > "$OUT/config/uxplay.service"
ssh_cmd 'cat /etc/modules-load.d/bcm2835-codec.conf' > "$OUT/config/bcm2835-codec.conf"
ssh_cmd 'cat /etc/udev/rules.d/99-bcm2835-codec.rules' > "$OUT/config/99-bcm2835-codec.rules"
ssh_cmd 'cat /boot/firmware/config.txt' > "$OUT/config/boot-config.txt"
ssh_cmd 'cat /boot/firmware/cmdline.txt' > "$OUT/config/boot-cmdline.txt"

echo "==> WiFi config: hash only + PSK-redacted template (never verbatim, see EXCLUDE-LIST.md)"
ssh_cmd 'sha256sum /etc/wpa_supplicant/wpa_supplicant.conf' > "$OUT/wpa_supplicant.sha256"
ssh_cmd "sed -E -e 's/(psk=).*/\1REDACTED/' -e 's/(ssid=).*/\1REDACTED/' /etc/wpa_supplicant/wpa_supplicant.conf" > "$OUT/config/wpa_supplicant.conf.template"

echo "==> uxplay_debug binary hash (for later Tier C comparison)"
ssh_cmd 'sha256sum /usr/local/bin/uxplay_debug' > "$OUT/uxplay_debug.sha256"

diff_count=$(wc -l < "$OUT/filetree-manifest.sha256")
echo
echo "==> Done: $OUT ($diff_count files hashed)"
