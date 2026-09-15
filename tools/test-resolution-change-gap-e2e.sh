#!/bin/bash
# Autonomous, reproducible measurement of the render gap that follows a
# "Received resolution change" event -- the ONE normal renegotiation that
# fires early in every real AirPlay mirroring session (v4l2h264dec settling
# on the client's actual SPS/colorimetry after an initial guess; see
# docs/bugs/2026-09-14-video-render-collapse.md). Confirmed present in the
# ORIGINAL, unmodified uxplay_debug (2026-09-14, both live and via replay)
# -- not a regression from any fix in this repo, just never measured before.
#
# tools/captures/resolution-change-gap-repro.cap (377KB, ~1s of a real
# mirroring session, trimmed from resend-fix-verify-20260914.cap by
# tools/trim-capture.py) is all that's needed: the resolution-change event
# fires within the first second of every session, so replaying a full
# multi-minute/multi-hundred-MB capture bought nothing but slower
# iteration. Confirmed deterministic across repeated runs on this
# fixture (gap=1 every time, matching the full-length capture's own
# measurement) before trimming it down this far.
#
# Reports how many frames decode between the resolution-change event and
# the next successful render. A bounded small number (a handful of frames)
# is the expected, largely-unavoidable cost of the renegotiation itself.
# "NEVER" (no render resumes before the capture ends) is the catastrophic
# collapse this project's render-health watchdog (UxPlay/uxplay.cpp's
# render_health_callback) exists to auto-recover from -- see
# tools/test-render-health-e2e.sh for the overall render/decode ratio
# check that catches that class of failure across a whole real session.
#
# Usage: tools/test-resolution-change-gap-e2e.sh [user@host] [extra uxplay_debug args...]
#   Pass extra args (e.g. -bt709) to test a candidate fix against the same
#   fixture. Set CAPTURE=path/to/other.cap to use a different capture.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-root@192.168.1.34}"
shift || true
EXTRA_ARGS=("$@")
CAPTURE="${CAPTURE:-tools/captures/resolution-change-gap-repro.cap}"

if [ ! -f "$CAPTURE" ]; then
  echo "Capture not found: $CAPTURE" >&2
  exit 1
fi

SSH_PASS="${UXPLAY_SSH_PASSWORD:-dietpi}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_r() { sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }
scp_to() { sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=accept-new "$1" "$TARGET:$2"; }
scp_from() { sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=accept-new "$TARGET:$1" "$2"; }

echo "==> Stopping live service (needs exclusive DRM master for replay)"
ssh_r "systemctl stop uxplay.service"
trap 'ssh_r "systemctl start uxplay.service" >/dev/null 2>&1 || true' EXIT

echo "==> Deploying $(basename "$CAPTURE") (extra args: ${EXTRA_ARGS[*]:-none})"
scp_to "$CAPTURE" /tmp/resgap-test.cap

ssh_r "
  GST_DEBUG=kmssink:6,v4l2videodec:5 timeout 15 stdbuf -oL -eL /usr/local/bin/uxplay_debug \
    -nohold -vd v4l2h264dec -vc identity -srgb no -n 'Living Room TV' -reset 60 \
    ${EXTRA_ARGS[*]:-} \
    -vs 'kmssink qos=false ts-offset=300000000' \
    -as 'alsasink device=plughw:vc4hdmi,0' \
    -replay /tmp/resgap-test.cap > /tmp/resgap-test.log 2>&1
  true
"
scp_from /tmp/resgap-test.log build/resgap-test.log
ssh_r "rm -f /tmp/resgap-test.cap /tmp/resgap-test.log"

awk '
  /Received resolution change/ { pending++; gap = 0; next }
  pending && /Handling frame/ { gap++; next }
  pending && /gst_kms_sink_import_dmabuf/ { print "gap=" gap; pending = 0; total_events++; next }
  END {
    if (total_events == 0 && !pending) { print "FAIL: no resolution-change event fired -- fixture or args broke the repro"; exit 1 }
    else if (pending) { print "gap=NEVER (render never resumed -- this is the collapse the watchdog exists for)" }
  }
' build/resgap-test.log
