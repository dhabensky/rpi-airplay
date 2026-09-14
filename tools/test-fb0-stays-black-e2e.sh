#!/bin/bash
# Autonomous regression test guarding against the DRM primary plane's
# backing buffer (/dev/fb0) getting re-dirtied by console text SOMETIME
# during a real boot, well after zero-fb0 (uxplay.service's ExecStartPre)
# already ran once, early. Whatever's on fb0 becomes visible wherever
# nothing else covers the screen -- the TV's pillarbox margins for
# non-16:9 content. A `-replay`-based test can't catch this at all, since
# -replay never goes through a real boot -- this needs the actual kernel
# cmdline / systemd boot sequence, so this test reboots the real device.
#
# Usage: tools/test-fb0-stays-black-e2e.sh [user@host] [settle_s]
#   settle_s: extra time to wait after uxplay.service is confirmed active,
#   before checking fb0 -- this is the whole point of the test (catching
#   console text that arrives AFTER the service is already up), so don't
#   shrink it without a real reason. Default is generous relative to how
#   long console cursor / late boot messages take to settle on a Pi 3B+
#   (well before the 2-minute mark).
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-root@192.168.1.34}"
SETTLE_S="${2:-90}"

HOST="${TARGET#*@}"
SSH_PASS="${UXPLAY_SSH_PASSWORD:-dietpi}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=10)
ssh_r() { sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

echo "==> Rebooting $TARGET (this test needs a REAL boot -- the bug is in"
echo "    what the kernel/systemd write to the console DURING boot, which"
echo "    -replay can never exercise)"
# The reboot command itself always reports a dbus-org.freedesktop.login1
# error on this device (a broken-but-harmless unit, see PROGRESS.md) --
# the reboot proceeds regardless, so don't treat that as failure.
ssh_r "reboot" >/dev/null 2>&1 || true

echo "==> Waiting for the device to go down"
for i in $(seq 1 30); do
  ping -c 1 -t 1 "$HOST" >/dev/null 2>&1 || { echo "  down after ${i}s"; break; }
  sleep 1
done

echo "==> Waiting for the device to come back up"
up=0
for i in $(seq 1 60); do
  if ping -c 1 -t 1 "$HOST" >/dev/null 2>&1; then
    up=1
    echo "  ping ok after ${i}s"
    break
  fi
  sleep 1
done
if [ "$up" -ne 1 ]; then
  echo "FAIL: device never came back up on the network after reboot"
  exit 1
fi

echo "==> Waiting for uxplay.service to become active"
active=0
for i in $(seq 1 60); do
  if ssh_r "systemctl is-active uxplay.service" 2>/dev/null | grep -q "^active$"; then
    active=1
    echo "  active after ${i}s of SSH being reachable"
    break
  fi
  sleep 2
done
if [ "$active" -ne 1 ]; then
  echo "FAIL: uxplay.service never became active after reboot"
  exit 1
fi

echo "==> Letting the boot sequence fully settle (${SETTLE_S}s) -- this is"
echo "    the actual regression window: console text can still arrive after"
echo "    the service above is already reported active"
sleep "$SETTLE_S"

echo "==> Checking /dev/fb0 is genuinely all-zero"
FB0_DIFF=$(ssh_r "cmp /dev/fb0 /dev/zero 2>&1" || true)
echo "  $FB0_DIFF"

if echo "$FB0_DIFF" | grep -q "^/dev/fb0 /dev/zero differ"; then
  echo
  echo "=== RESULT: FAIL -- /dev/fb0 has non-zero content well after boot ==="
  echo "Whatever's on fb0 shows through the TV's pillarbox margins during"
  echo "mirroring. Pull a copy and look at it:"
  echo "  sshpass -p $SSH_PASS scp ${SSH_OPTS[*]} $TARGET:/dev/fb0 build/fb0-fail.raw"
  echo "  ffmpeg -f rawvideo -pixel_format rgb565le -video_size 1920x1080 \\"
  echo "    -i build/fb0-fail.raw -frames:v 1 build/fb0-fail.png"
  exit 1
fi

echo
echo "=== RESULT: PASS -- /dev/fb0 stayed black through a real boot + ${SETTLE_S}s settle ==="
