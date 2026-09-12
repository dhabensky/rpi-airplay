#!/bin/bash
# Customizes the extracted boot (FAT32) partition directory: applies the
# config.txt/cmdline.txt tuning that was previously only ever done by hand,
# directly on the live Pi, and never captured into any script here --
# invisible to every `make verify` run so far because tools/compare-rebuild.sh's
# Tier B only ever diffed the ROOT partition, never boot (fixed alongside
# this). Confirmed against golden-reference/snapshots/*/config/boot-config.txt
# (a verbatim capture of the live Pi's actual file) -- these are the only
# 4 lines that differ from the pristine base image's own config.txt/cmdline.txt.
#
# Usage: image-builder/customize-boot.sh <boot-dir> [personal-env-file]
set -euo pipefail

bootdir="${1:?usage: $0 <boot-dir> [personal-env-file]}"
personal_env="${2:-}"

echo "==> Fixing GPU memory split (16 -> 128 -- 16MB is nowhere near enough for"
echo "    real video decode/display work)"
sed -i 's/^gpu_mem_1024=.*/gpu_mem_1024=128/' "$bootdir/config.txt"

echo "==> Raising thermal throttle limit to match the tuned live-Pi config (65 -> 75)"
sed -i 's/^temp_limit=.*/temp_limit=75/' "$bootdir/config.txt"

echo "==> Enabling the KMS/DRM display driver (dtoverlay=vc4-kms-v3d) -- NOT"
echo "    optional: uxplay.service's kmssink requires /dev/dri/card0, which"
echo "    only exists with this overlay active. The base image ships it"
echo "    disabled by default; without this fix every image built by this"
echo "    pipeline would fail to display anything at all on real hardware."
sed -i 's/^#dtoverlay=vc4-kms-v3d,noaudio$/dtoverlay=vc4-kms-v3d/' "$bootdir/config.txt"

echo "==> Matching the (inert, both commented-out) overclock example values too"
echo "    -- purely cosmetic byte-parity with golden-reference, no functional"
echo "    effect either way since both are comments"
sed -i \
  -e 's/^#arm_freq=.*/#arm_freq=1400/' \
  -e 's/^#core_freq=.*/#core_freq=400/' \
  -e 's/^#sdram_freq=.*/#sdram_freq=500/' \
  "$bootdir/config.txt"

echo "==> Matching cmdline.txt: ttyS0 (not the serial0 alias) + vc4.force_hotplug=1"
sed -i \
  -e 's/console=serial0,115200/console=ttyS0,115200/' \
  -e 's/$/ vc4.force_hotplug=1/' \
  "$bootdir/cmdline.txt"

echo "==> Enabling DietPi's automated WiFi setup (dietpi.txt ships with it OFF"
echo "    by default). This is separate from and additional to filling in"
echo "    dietpi-wifi.txt with real credentials at flash time -- without this"
echo "    flag DietPi never even attempts to bring up wlan0, only eth0, which"
echo "    has no cable on this deployment -- so the device never gets network"
echo "    at all, no matter what's in dietpi-wifi.txt."
sed -i 's/^AUTO_SETUP_NET_WIFI_ENABLED=.*/AUTO_SETUP_NET_WIFI_ENABLED=1/' "$bootdir/dietpi.txt"

echo "==> Setting hostname to rpi-airplay (base image ships the generic"
echo "    'DietPi' default; the live Pi has always been rpi-airplay,"
echo "    hand-set at some undocumented point, never previously scripted)"
sed -i 's/^AUTO_SETUP_NET_HOSTNAME=.*/AUTO_SETUP_NET_HOSTNAME=rpi-airplay/' "$bootdir/dietpi.txt"

echo "==> Making first boot fully non-interactive and self-contained -- this"
echo "    image should be a 'flash it and use it' appliance, not something"
echo "    that pauses for prompts or phones home for updates on first boot:"
echo "    - AUTO_SETUP_AUTOMATED=1: skip DietPi's interactive first-run wizard"
echo "    - SURVEY_OPTED_IN=-1 (undecided) otherwise prompts interactively;"
echo "      explicitly opt out instead"
echo "    - CONFIG_CHECK_DIETPI_UPDATES/CONFIG_CHECK_APT_UPDATES=0: this"
echo "      project already controls exactly what's installed and when it's"
echo "      updated (see 'make refresh-base-image') -- letting DietPi silently"
echo "      apt-upgrade itself later reintroduces the version drift this"
echo "      whole reproducible-build pipeline exists to avoid"
sed -i \
  -e 's/^AUTO_SETUP_AUTOMATED=.*/AUTO_SETUP_AUTOMATED=1/' \
  -e 's/^SURVEY_OPTED_IN=.*/SURVEY_OPTED_IN=0/' \
  -e 's/^CONFIG_CHECK_DIETPI_UPDATES=.*/CONFIG_CHECK_DIETPI_UPDATES=0/' \
  -e 's/^CONFIG_CHECK_APT_UPDATES=.*/CONFIG_CHECK_APT_UPDATES=0/' \
  "$bootdir/dietpi.txt"

if [ -n "$personal_env" ] && [ -f "$personal_env" ]; then
  # shellcheck disable=SC1090
  . "$personal_env"
  if [ -n "${WIFI_SSID:-}" ]; then
    echo "==> Filling in WiFi credentials from personal.env (entry 0)"
    # DietPi's own documented escaping rule for dietpi-wifi.txt (see the
    # file's own header comment): a literal single quote in the value must
    # become '\'' inside the surrounding single-quoted assignment.
    esc_ssid=$(printf '%s' "$WIFI_SSID" | sed "s/'/'\\\\''/g")
    esc_key=$(printf '%s' "${WIFI_PASSWORD:-}" | sed "s/'/'\\\\''/g")
    # awk, not sed -- sed's own change/substitute commands treat a
    # backslash in the REPLACEMENT text as an escape character (consuming
    # it), which silently corrupts the '\'' escape sequence above the
    # instant it contains one. Confirmed empirically: sed's `c\` ate the
    # backslash, producing `'''` instead of `'\''`. awk's plain string
    # printing has no such reinterpretation.
    awk -v ssid="$esc_ssid" -v key="$esc_key" '
      /^aWIFI_SSID\[0\]=/  { print "aWIFI_SSID[0]='"'"'"  ssid "'"'"'"; next }
      /^aWIFI_KEY\[0\]=/   { print "aWIFI_KEY[0]='"'"'"   key  "'"'"'"; next }
      /^aWIFI_KEYMGR\[0\]=/{ print "aWIFI_KEYMGR[0]='"'"'WPA-PSK'"'"'"; next }
      { print }
    ' "$bootdir/dietpi-wifi.txt" > "$bootdir/dietpi-wifi.txt.new"
    mv "$bootdir/dietpi-wifi.txt.new" "$bootdir/dietpi-wifi.txt"
  fi
fi

echo "Boot customization complete: $bootdir"
