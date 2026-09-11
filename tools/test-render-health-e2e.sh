#!/bin/bash
# Autonomous regression test against REAL captured AirPlay sessions -- no Mac,
# no live client, no user interaction. Exists because of a real bug (2026-09-11,
# see PROGRESS.md) that only reproduced with a real client's actual traffic:
# kmssink's decoded-frame render rate collapsed to ~1.3fps for a specific
# client's non-native-resolution content, while a 90s *synthetic* ffmpeg
# capture rendered perfectly the whole time -- synthetic content didn't carry
# whatever real macOS AirPlay encoding characteristic triggered it. Real
# `-capture` recordings in tools/captures/ (gitignored, kept locally -- see
# that dir) are the only thing that reliably reproduces this class of bug, so
# this test replays every one of them and asserts a healthy render/decode
# ratio, instead of asking a human to re-mirror their screen for every future
# kmssink/v4l2h264dec pipeline change.
#
# Usage: tools/test-render-health-e2e.sh [user@host] [min_ratio_pct]
#   Replays every tools/captures/*.cap file found. A capture with essentially
#   no video (audio-only debugging sessions, etc.) is skipped automatically
#   (near-zero decode events -> nothing meaningful to assert).
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-root@192.168.1.34}"
MIN_RATIO="${2:-70}"   # percent: render_events / decode_events must be >= this

# Password auth, no key set up on this device (see PROGRESS.md's "Useful
# one-off diagnostic commands"). PubkeyAuthentication=no forces password
# auth immediately instead of burning through MaxAuthTries on offered keys
# first and getting disconnected before the password prompt is ever reached.
SSH_PASS="${UXPLAY_SSH_PASSWORD:-dietpi}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() { sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }
scp_to() { sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=accept-new "$1" "$TARGET:$2"; }
scp_from() { sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=accept-new "$TARGET:$1" "$2"; }

shopt -s nullglob
CAPTURES=(tools/captures/*.cap)
if [ ${#CAPTURES[@]} -eq 0 ]; then
  echo "No captures found in tools/captures/ -- nothing to test."
  echo "See PROGRESS.md's 'Methodology note' (2026-09-11 entry) for how to add one:"
  echo "  enable -capture on the live service, get a real session, save the .cap here."
  exit 0
fi

echo "==> Stopping live service (needs exclusive DRM master for replay)"
ssh_r "systemctl stop uxplay.service"
trap 'ssh_r "systemctl start uxplay.service" >/dev/null 2>&1 || true' EXIT

fail=0
for cap in "${CAPTURES[@]}"; do
  name="$(basename "$cap")"
  echo
  echo "=== $name ==="
  echo "==> Deploying"
  scp_to "$cap" /tmp/render-health-test.cap

  echo "==> Replaying with GST_DEBUG render/decode instrumentation"
  ssh_r "
    GST_DEBUG=kmssink:6,v4l2videodec:5 timeout 90 stdbuf -oL -eL /usr/local/bin/uxplay_debug \
      -nohold -vd v4l2h264dec -vc identity -srgb no -n 'Living Room TV' -reset 60 \
      -vs 'kmssink qos=false ts-offset=300000000' \
      -as 'alsasink device=plughw:vc4hdmi,0' \
      -replay /tmp/render-health-test.cap > /tmp/render-health-test.log 2>&1
    true
  "
  scp_from /tmp/render-health-test.log "build/render-health-${name}.log"
  ssh_r "rm -f /tmp/render-health-test.cap /tmp/render-health-test.log"

  render=$(grep -c "gst_kms_sink_import_dmabuf" "build/render-health-${name}.log" || true)
  decode=$(grep -c "Handling frame" "build/render-health-${name}.log" || true)

  if [ "$decode" -lt 20 ]; then
    echo "SKIP: only $decode decode events (not enough real video in this capture) -- see build/render-health-${name}.log"
    continue
  fi

  ratio=$(( render * 100 / decode ))
  echo "render events: $render / decode events: $decode  ($ratio%)"

  if [ "$ratio" -lt "$MIN_RATIO" ]; then
    echo "FAIL: render/decode ratio $ratio% < required $MIN_RATIO% -- see build/render-health-${name}.log"
    fail=1
  else
    echo "PASS"
  fi
done

echo
if [ "$fail" -ne 0 ]; then
  echo "=== RESULT: FAIL -- one or more real captures show a render stall ==="
  exit 1
fi
echo "=== RESULT: PASS -- all real captures render at a healthy rate ==="
