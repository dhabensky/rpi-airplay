#!/bin/bash
# Autonomous end-to-end test for the video reconnect path (skip_video_rebuild
# / video_reset(RESET_TYPE_RTP_SHUTDOWN)) against REAL Pi hardware -- no Mac,
# no AirPlay client, no UI automation. Exists because this exact class of bug
# (the v4l2h264dec hardware decoder firmware wedging on pipeline
# destroy+recreate, see uxplay.cpp's skip_video_rebuild comment) is
# hardware-specific and can only be reproduced/caught on the real device, and
# because there's no scriptable way to trigger a real AirPlay mirror session
# (see make-synthetic-cap.py's header for why).
#
# How it works: synthesizes a valid .cap file from a locally-generated H.264
# test stream, deploys it to the Pi, runs uxplay_debug in -replay mode with
# UX_RECONNECT_MODE=real (the actual production reconnect code path) and
# UX_RECONNECT_AT_MS set to fire partway through, with GST_DEBUG=kmssink:6
# enabled. Verification: count kmssink's gst_kms_sink_import_dmabuf log lines
# (one per actually-rendered frame) before vs after the simulated reconnect --
# a wedged decoder would show render activity stop dead after reconnect while
# the feeder keeps accepting input (matches the documented bug's own
# "keeps accepting compressed input via qbuf but never produces decoded
# output again" symptom). A frame-buffer/fbdev pixel-diff approach was tried
# first and abandoned: /dev/fb0 on this vc4-kms-v3d setup reflects the
# fbcon text console, NOT kmssink's actual DRM plane output -- completely
# disconnected from what's really being rendered.
#
# Usage: tools/test-reconnect-e2e.sh [user@host] [duration_s] [reconnect_at_s]
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-root@192.168.1.34}"
DURATION="${2:-24}"
RECONNECT_AT="${3:-12}"

# Password auth, no key set up on this device (matches the other e2e
# scripts here -- see tools/test-render-health-e2e.sh). Plain ssh/scp hang
# waiting for an interactive password prompt that never comes.
SSH_PASS="${UXPLAY_SSH_PASSWORD:-dietpi}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh() { sshpass -p "$SSH_PASS" /usr/bin/ssh "${SSH_OPTS[@]}" "$@"; }
scp() { sshpass -p "$SSH_PASS" /usr/bin/scp -o StrictHostKeyChecking=accept-new "$@"; }
# Under build/, not system mktemp -d: macOS's real tmp dir (/var/folders/...)
# isn't shared into colima's VM, so a Docker bind-mount onto it silently
# produces an empty view from inside the container (confirmed the hard way
# earlier in this project -- see the .dockerignore/build-optimization
# history). build/ is already the project's established Docker-shared
# scratch area.
WORKDIR="$PWD/build/reconnect-test-$$"
mkdir -p "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Generating ${DURATION}s synthetic H.264 test stream"
docker run --rm -v "$WORKDIR":/out debian:trixie-slim bash -c "
  apt-get update -qq >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg >/dev/null 2>&1
  ffmpeg -y -f lavfi -i 'testsrc=size=640x480:rate=10:duration=${DURATION}' \
    -c:v libx264 -profile:v baseline -pix_fmt yuv420p \
    -x264-params keyint=10:scenecut=0 -f h264 /out/test.h264 2>&1 | tail -5
"

echo "==> Packing into .cap format"
python3 tools/make-synthetic-cap.py "$WORKDIR/test.h264" "$WORKDIR/test.cap" 10

echo "==> Deploying to $TARGET"
scp -q "$WORKDIR/test.cap" "$TARGET:/tmp/test-reconnect.cap"

echo "==> Stopping live service (needs exclusive DRM master for the test)"
ssh "$TARGET" "systemctl stop uxplay.service"

echo "==> Running replay with simulated reconnect at ${RECONNECT_AT}s"
RECONNECT_MS=$((RECONNECT_AT * 1000))
ssh "$TARGET" "
  cd /tmp
  GST_DEBUG=kmssink:6 UX_RECONNECT_MODE=real UX_RECONNECT_AT_MS=${RECONNECT_MS} \
    stdbuf -oL -eL /usr/local/bin/uxplay_debug \
    -nohold -vd v4l2h264dec -vc identity -srgb no -n 'Living Room TV' -reset 60 \
    -vs 'kmssink qos=false ts-offset=300000000' \
    -as 'alsasink device=plughw:vc4hdmi,0' \
    -replay /tmp/test-reconnect.cap > /tmp/test-reconnect.log 2>&1
  echo exit_code=\$?
"

echo "==> Restoring live service"
ssh "$TARGET" "systemctl start uxplay.service"

echo "==> Fetching log"
scp -q "$TARGET:/tmp/test-reconnect.log" "$WORKDIR/replay.log"
# Kept outside WORKDIR (which the EXIT trap deletes) so the log survives a
# FAIL for inspection regardless of exit path.
cp "$WORKDIR/replay.log" "$PWD/build/reconnect-test-last.log"
ssh "$TARGET" "rm -f /tmp/test-reconnect.cap /tmp/test-reconnect.log"

RECONNECT_LINE=$(grep -n "RECONNECT DONE" "$WORKDIR/replay.log" | cut -d: -f1 || true)
if [ -z "$RECONNECT_LINE" ]; then
  echo "FAIL: 'RECONNECT DONE' never appeared in the log -- reconnect simulation didn't fire"
  exit 1
fi
BEFORE=$(head -n "$RECONNECT_LINE" "$WORKDIR/replay.log" | grep -c "gst_kms_sink_import_dmabuf" || true)
AFTER=$(tail -n +"$RECONNECT_LINE" "$WORKDIR/replay.log" | grep -c "gst_kms_sink_import_dmabuf" || true)
FRAMES_DONE=$(grep -o "replay: done ([0-9]* video" "$WORKDIR/replay.log" | grep -o "[0-9]*" || echo 0)

echo
echo "=== RESULT ==="
echo "kmssink render events before reconnect: $BEFORE"
echo "kmssink render events after reconnect:  $AFTER"
echo "video frames fed by replay:             $FRAMES_DONE"

if [ "$AFTER" -lt 10 ]; then
  echo "FAIL: kmssink rendered almost nothing after the simulated reconnect --"
  echo "  this is the signature of the v4l2h264dec wedging bug (pipeline"
  echo "  destroy+recreate leaves the decoder firmware stuck). See:"
  echo "  build/reconnect-test-last.log"
  exit 1
fi
echo "PASS: kmssink kept rendering after the simulated reconnect"
