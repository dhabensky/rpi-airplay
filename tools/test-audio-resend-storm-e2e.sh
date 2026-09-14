#!/bin/bash
# Regression test for the audio resend-request flood
# (lib/raop_buffer.c, see docs/bugs/2026-09-14-audio-resume-latency-on-seek.md).
# Builds the current working tree and runs a scripted client
# (`-resendstormcheck`, uxplay.cpp) that opts into the real resend-wait
# path (a real, non-zero controlPort -- every other driver mode here
# deliberately avoids this), creates a permanent 3-packet gap, and keeps
# sending one audio packet every ~5ms for 1s while counting how many
# distinct resend-request packets the server sends back for that gap.
#
# Confirmed empirically while writing this fix: unfixed code sends one
# duplicate resend request per incoming packet (200 requests for 200
# packets sent at 5ms spacing over 1s -- matches a real live capture's
# ~760 duplicate requests per ~2.8s real audio dropout, see the bug doc).
# Fixed code (100ms rate limit, RAOP_RESEND_MIN_INTERVAL_NS in
# lib/raop_buffer.c) sends 10 in the same window, every time.
#
# Tests ONLY the current revision -- no checkout, no building a second
# binary from another ref. Validating that this same check shows the
# flood against the pre-fix code is a one-time, manual step done once
# while writing the fix (see memory: bug_fix_protocol), not something
# this script does.
#
# Runs entirely in Docker, no live client or Pi hardware needed.
set -euo pipefail
cd "$(dirname "$0")/.."

# Comfortably between the fixed (~10) and unfixed (~200) counts -- wide
# margin either side to avoid flakiness from timing jitter.
THRESHOLD="${1:-30}"

run_check() {
  local logfile="$1"
  docker run --rm -v "$PWD/build/uxplay_debug":/usr/local/bin/uxplay:ro \
    rpi-airplay-buildenv /usr/local/bin/uxplay -vs 0 -resendstormcheck > "$logfile" 2>&1 &
  local pid=$!
  sleep 4
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

verdict() {
  local logfile="$1" threshold="$2"
  python3 - "$logfile" "$threshold" <<'PYEOF'
import re, sys
logfile, threshold = sys.argv[1], int(sys.argv[2])
log = open(logfile).read()
m = re.search(r"RESEND-REQUEST-COUNT (\d+) \(in ([\d.]+)s, sent (\d+) keepalive packets\)", log)
if not m:
    print("INCOMPLETE")
    sys.exit(0)
count, window_s, sent = int(m.group(1)), float(m.group(2)), int(m.group(3))
print(f"count={count} threshold={threshold} sent={sent} window={window_s}s")
print("PASS" if count <= threshold else "FAIL")
PYEOF
}

echo "==> Building current working tree"
make uxplay

echo "==> Running -resendstormcheck"
run_check build/logs/resend-storm-check.log
result=$(verdict build/logs/resend-storm-check.log "$THRESHOLD")
echo "$result"

if echo "$result" | tail -1 | grep -q "^PASS$"; then
  echo "PASS"
  exit 0
else
  echo "FAIL: resend-request count exceeded threshold ($THRESHOLD)"
  echo "See build/logs/resend-storm-check.log"
  exit 1
fi
