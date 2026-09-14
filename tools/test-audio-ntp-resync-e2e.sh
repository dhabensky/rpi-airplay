#!/bin/bash
# Regression test for the NTP-sync-state-not-reset-on-restart bug
# (lib/raop_rtp.c, see docs/audio-pipeline.md). Builds the current working
# tree and runs a scripted client (`-ntpresynccheck`, uxplay.cpp) that
# establishes a real session and sync, restarts it, and sends a probe
# packet before any new sync arrives -- asserting the fix's behavior:
# that packet must be withheld until a fresh sync arrives, then render
# with a timestamp consistent with a later, correctly-synced probe.
#
# Tests ONLY the current revision -- no checkout, no building a second
# binary from another ref. Validating that this same check FAILS against
# the pre-fix code is a one-time, manual step done once while writing the
# test (see memory: bug_fix_protocol), not something this script does.
#
# Runs entirely in Docker, no live client or Pi hardware needed.
set -euo pipefail
cd "$(dirname "$0")/.."

run_check() {
  local logfile="$1"
  docker run --rm -v "$PWD/build/uxplay_debug":/usr/local/bin/uxplay:ro \
    rpi-airplay-buildenv /usr/local/bin/uxplay -vs 0 -ntpresynccheck > "$logfile" 2>&1 &
  local pid=$!
  sleep 4
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Reads a -ntpresynccheck log and prints BUG-PRESENT, FIXED, or INCOMPLETE.
# BUG-PRESENT: probe A (sent before the second sync packet) either rendered
# before that sync arrived, or rendered with an ntp_time inconsistent with
# probe B's (expected delta: 100 RTP ticks @ 44100Hz =~ 2.267ms). FIXED:
# probe A was withheld until the sync, then rendered with a consistent,
# sane delta relative to probe B.
verdict() {
  local logfile="$1"
  python3 - "$logfile" <<'PYEOF'
import re, sys
log = open(sys.argv[1]).read()
def t(pattern):
    m = re.search(pattern, log)
    return float(m.group(1)) if m else None
sent_sync2 = t(r"SENT-SYNC-2 t=([\d.]+)")
renders = re.findall(r"RENDER-BUFFER-CALL t=([\d.]+) seqnum=(\d+) ntp_time=(\d+)", log)
render_a = next((r for r in renders if r[1] == '1'), None)
render_b = next((r for r in renders if r[1] == '2'), None)
if sent_sync2 is None or not render_a or not render_b:
    print("INCOMPLETE")
    sys.exit(0)
render_a_t = float(render_a[0])
ntp_a = int(render_a[2])
ntp_b = int(render_b[2])
delta_ns = abs(ntp_b - ntp_a)
expected_ns = 100 / 44100 * 1e9  # 100 RTP ticks @ 44100Hz
sane = abs(delta_ns - expected_ns) < 50_000_000  # 50ms tolerance
rendered_before_sync = render_a_t < sent_sync2
print("BUG-PRESENT" if (rendered_before_sync or not sane) else "FIXED")
PYEOF
}

echo "==> Building current working tree"
make uxplay

echo "==> Running -ntpresynccheck"
run_check /tmp/ntpresync-check.log
result=$(verdict /tmp/ntpresync-check.log)
echo "    verdict: $result"

if [ "$result" = "FIXED" ]; then
  echo "PASS"
  exit 0
else
  echo "FAIL: expected FIXED, got $result"
  echo "See /tmp/ntpresync-check.log"
  exit 1
fi
