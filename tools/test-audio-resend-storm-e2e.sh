#!/bin/bash
# Regression test for the real ~2.8s audio dropout on a lost packet
# (see docs/bugs/2026-09-14-audio-resume-latency-on-seek.md). Builds the
# current working tree and runs a scripted client (`-resendstormcheck`,
# uxplay.cpp) that opts into the real resend-wait path (a real, non-zero
# controlPort -- every other driver mode here deliberately avoids this),
# creates a permanent 3-packet gap, and keeps sending one audio packet at
# AAC-ELD's real cadence (~10.9ms, spf=480 @ 44100Hz) for 3.5s.
#
# Two things get asserted:
# - RESOLVED-AT: how long until the server stops asking for the missing
#   packet at all -- either a genuine resend succeeded or
#   raop_buffer_dequeue()'s stall-timeout force-skip gave up on it. This
#   is the real recovery-time metric, and the one that matters: a first
#   fix here (rate-limiting duplicate resend requests,
#   RAOP_RESEND_MIN_INTERVAL_NS) cut request volume ~30x on a real
#   capture with ZERO effect on this number -- confirmed by deploying it
#   alone and getting a real "no effect" report. The actual bottleneck
#   was raop_buffer_dequeue() refusing to skip a stuck packet until the
#   full 256-entry buffer capacity was exhausted, which at real AAC-ELD
#   cadence takes ~2.79s regardless of resend traffic.
#   RAOP_STALL_TIMEOUT_NS (lib/raop_buffer.c) bounds this independent of
#   buffer capacity.
# - RESEND-REQUEST-COUNT: still meaningful as a secondary signal (the
#   rate-limit fix is real and worth keeping -- less redundant network
#   traffic during exactly the window that's already congested), just not
#   the metric that predicts audible dropout duration.
#
# Tests ONLY the current revision -- no checkout, no building a second
# binary from another ref. Validating that this same check shows the
# ~2.8s-class stall against pre-fix code is a one-time, manual step done
# once while writing each fix (see memory: bug_fix_protocol), not
# something this script does.
#
# Runs entirely in Docker, no live client or Pi hardware needed.
set -euo pipefail
cd "$(dirname "$0")/.."

# Comfortable margin over the observed ~0.10-0.11s (fixed) and the 500ms
# requirement, while nowhere near the ~2.7s unfixed baseline.
RESOLVED_THRESHOLD_S="${1:-0.3}"
COUNT_THRESHOLD="${2:-30}"

run_check() {
  local logfile="$1"
  docker run --rm -v "$PWD/build/uxplay_debug":/usr/local/bin/uxplay:ro \
    rpi-airplay-buildenv /usr/local/bin/uxplay -vs 0 -resendstormcheck > "$logfile" 2>&1 &
  local pid=$!
  sleep 6
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

verdict() {
  local logfile="$1" resolved_threshold="$2" count_threshold="$3"
  python3 - "$logfile" "$resolved_threshold" "$count_threshold" <<'PYEOF'
import re, sys
logfile, resolved_threshold, count_threshold = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
log = open(logfile).read()

m_count = re.search(r"RESEND-REQUEST-COUNT (\d+) \(in ([\d.]+)s, sent (\d+) keepalive packets\)", log)
m_resolved = re.search(r"RESOLVED-AT (-?[\d.]+)", log)
if not m_count or not m_resolved:
    print("INCOMPLETE")
    sys.exit(0)

count, window_s, sent = int(m_count.group(1)), float(m_count.group(2)), int(m_count.group(3))
resolved_at = float(m_resolved.group(1))
print(f"count={count} count_threshold={count_threshold} sent={sent} window={window_s}s")
print(f"resolved_at={resolved_at:.4f}s resolved_threshold={resolved_threshold}s")

if resolved_at < 0:
    print("FAIL: never resolved -- no resend-request seen at all (never stopped asking)")
    sys.exit(0)
ok = (resolved_at <= resolved_threshold) and (count <= count_threshold)
print("PASS" if ok else "FAIL")
PYEOF
}

echo "==> Building current working tree"
make uxplay

echo "==> Running -resendstormcheck"
run_check build/logs/resend-storm-check.log
result=$(verdict build/logs/resend-storm-check.log "$RESOLVED_THRESHOLD_S" "$COUNT_THRESHOLD")
echo "$result"

if echo "$result" | tail -1 | grep -q "^PASS$"; then
  echo "PASS"
  exit 0
else
  echo "FAIL: see build/logs/resend-storm-check.log"
  exit 1
fi
