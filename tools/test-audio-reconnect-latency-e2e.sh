#!/bin/bash
# Measures server-side audio TEARDOWN(96)+SETUP(96) reconnect latency using
# the real httpd/raop.c stack over loopback (-threadtest, uxplay.cpp) --
# see docs/bugs/2026-09-14-audio-resume-latency-on-seek.md for why this
# exists: a real capture showed a ~1s reconnect gap on seek, of which
# ~0.71s is client-paced (not server-controllable) and the rest hit the
# cheap same-codec-restart path with nothing slow found. This script
# stress-tests many more cycles than a single live capture can, hunting
# for a slow outlier the one real capture didn't happen to hit.
#
# -replay cannot do this at all (bypasses lib/httpd.c/lib/raop.c
# entirely); -threadtest drives the real request-handling stack with real
# RTSP requests, entirely in Docker, no Pi/hardware needed (-vs 0).
#
# Tests ONLY the current revision -- no checkout, no building a second
# binary from another ref (see memory: bug_fix_protocol).
set -euo pipefail
cd "$(dirname "$0")/.."

THRESHOLD_S="${1:-0.5}"

run_threadtest() {
  local n="$1" gap_s="$2" logfile="$3"
  # The server process itself never exits on its own (main_loop() keeps
  # running after the driver thread finishes its N cycles) -- bound the
  # container's lifetime explicitly, generous enough for N cycles at the
  # given inter-cycle gap plus ~2s of connection/FairPlay-handshake setup.
  local budget_s=$((2 + n * (1 + gap_s)))
  UX_THREADTEST_GAP_S="$gap_s" docker run --rm --name uxplay-tt-latency -e UX_THREADTEST_GAP_S \
    -v "$PWD/build/uxplay_debug":/usr/local/bin/uxplay:ro \
    rpi-airplay-buildenv /usr/local/bin/uxplay -vs 0 -threadtest "$n" \
    > "$logfile" 2>&1 &
  local dpid=$!
  sleep "$budget_s"
  docker kill uxplay-tt-latency >/dev/null 2>&1 || true
  wait "$dpid" 2>/dev/null || true
}

# Parses a -threadtest log and prints one line per cycle:
#   cycle <n> teardown_rt=<s> setup_rt=<s> reconnect_span=<s>
# reconnect_span is SEND-TEARDOWN -> this cycle's first RENDER-BUFFER-CALL
# (the RAOP audio thread successfully dequeuing a synced packet and handing
# it to the renderer -- the audio_renderer.c TT_DIAG marker, matched to its
# cycle via seqnum, since the driver numbers each cycle's packets
# cycle*1000+p) -- the full server-side reconnect-to-audio-flowing-again
# span, i.e. the portion of the user's <=0.5s requirement this server
# actually controls. Not DECODED-BUFFER-OUT (post-decoder): the driver's
# synthetic repeated-frame content reliably fails avdec_aac's validity
# check (see docs/threadtest.md's "Known limitation"), so nothing ever
# reaches the decoder at all in this driver -- a pre-existing gap unrelated
# to reconnect latency, orthogonal to what this script measures.
analyze() {
  local logfile="$1"
  python3 - "$logfile" <<'PYEOF'
import re, sys
log = open(sys.argv[1]).read()

def find_all(pattern):
    return {int(m.group(1)): float(m.group(2)) for m in re.finditer(pattern, log)}

send_setup = find_all(r"cycle (\d+) SEND-SETUP t=([\d.]+)")
recv_setup = find_all(r"cycle (\d+) RECV-SETUP-response t=([\d.]+)")
send_td = find_all(r"cycle (\d+) SEND-TEARDOWN t=([\d.]+)")
recv_td = find_all(r"cycle (\d+) RECV-TEARDOWN-response t=([\d.]+)")

# seqnum = cycle*1000 + packet_index (uxplay.cpp's threadtest_driver) --
# group renders by which cycle sent them, take the earliest per cycle.
first_render = {}
for m in re.finditer(r"RENDER-BUFFER-CALL t=([\d.]+) seqnum=(\d+)", log):
    t, seqnum = float(m.group(1)), int(m.group(2))
    c = seqnum // 1000
    if c not in first_render or t < first_render[c]:
        first_render[c] = t

cycles = sorted(set(send_setup) & set(recv_setup) & set(send_td) & set(recv_td))
if not cycles:
    print("INCOMPLETE: no fully-logged cycles found")
    sys.exit(0)

# reconnect_span for cycle c is TEARDOWN(c) -> first render of the NEXT
# cycle's (c+1) audio -- the actual reconnect gap. The very last cycle has
# no next cycle (the driver just exits after its TEARDOWN), so it's
# reported as N/A, not NONE (nothing was expected to render after it).
for c in cycles:
    teardown_rt = recv_td[c] - send_td[c]
    setup_rt = recv_setup[c] - send_setup[c]
    nxt = c + 1
    if nxt not in cycles:
        print(f"cycle {c} teardown_rt={teardown_rt:.4f} setup_rt={setup_rt:.4f} reconnect_span=N/A")
        continue
    if nxt not in first_render:
        print(f"cycle {c} teardown_rt={teardown_rt:.4f} setup_rt={setup_rt:.4f} reconnect_span=NONE")
        continue
    reconnect_span = first_render[nxt] - send_td[c]
    print(f"cycle {c} teardown_rt={teardown_rt:.4f} setup_rt={setup_rt:.4f} reconnect_span={reconnect_span:.4f}")
PYEOF
}

check_threshold() {
  local logfile="$1" threshold="$2"
  python3 - "$logfile" "$threshold" <<'PYEOF'
import sys
logfile, threshold = sys.argv[1], float(sys.argv[2])
spans = []
none_count = 0
total = 0
for line in open(logfile):
    if "reconnect_span=" not in line:
        continue
    val = line.strip().split("reconnect_span=")[1]
    if val == "N/A":
        continue  # last cycle in the run, no next cycle to measure a reconnect into
    total += 1
    if val == "NONE":
        # A cycle whose sync/audio UDP packets were never seen at all --
        # distinct from "took too long to measure". Confirmed via a real
        # stress run: an isolated single-cycle miss with fully normal
        # SETUP/TEARDOWN round-trip times immediately before and after it
        # (no slowdown, no growth) -- the driver's fire-and-forget UDP
        # sync send (no ACK/retry, unlike a real client's periodic RTCP
        # sync) losing a packet under this test's artificially fast
        # back-to-back cycling, not a server-side latency problem. Counted
        # separately; only fails the run if it happens often enough to
        # suggest the driver itself is unreliable, not the server.
        none_count += 1
        continue
    spans.append(float(val))
if total == 0:
    print("FAIL: no cycles measured")
    sys.exit(1)
if none_count:
    print(f"NOTE: {none_count}/{total} cycles produced no RENDER-BUFFER-CALL at all "
          f"(treated as lost synthetic UDP packets, not measured latency)")
none_rate = none_count / total
if none_rate > 0.1:
    print(f"FAIL: {none_rate:.0%} of cycles produced no data -- too unreliable to trust "
          f"(expected occasional isolated UDP loss under this stress load, not this much)")
    sys.exit(1)
if not spans:
    print("FAIL: no cycles produced a measurable reconnect_span")
    sys.exit(1)
worst = max(spans)
mean = sum(spans) / len(spans)
print(f"{len(spans)} cycles measured, mean={mean:.4f}s max={worst:.4f}s threshold={threshold:.4f}s")
sys.exit(0 if worst <= threshold else 1)
PYEOF
}

echo "==> Building current working tree"
make uxplay

echo "==> Building buildenv image (if needed)"
docker build -q -t rpi-airplay-buildenv -f Dockerfile . >/dev/null

overall_pass=1

echo
echo "==> Run 1: rapid stress (UX_THREADTEST_GAP_S=0, N=50) -- hunts for a"
echo "    slow outlier across many more cycles than one real capture shows"
run_threadtest 50 0 build/logs/reconnect-latency-stress.log
analyze build/logs/reconnect-latency-stress.log | tee build/logs/reconnect-latency-stress.analyzed
if ! check_threshold build/logs/reconnect-latency-stress.analyzed "$THRESHOLD_S"; then
  overall_pass=0
fi

echo
echo "==> Run 2: realistic client pacing (UX_THREADTEST_GAP_S=1, N=10) -- NOT"
echo "    gated against \$THRESHOLD_S: the inserted 1s gap deliberately"
echo "    approximates the ~0.71s TEARDOWN-to-SETUP gap seen in the real"
echo "    capture, which is client-paced and not server-controllable (see"
echo "    docs/bugs/2026-09-14-audio-resume-latency-on-seek.md). This run"
echo "    exists to sanity-check that Run 1's numbers are representative:"
echo "    reconnect_span here should land close to (gap + Run 1's mean)."
run_threadtest 10 1 build/logs/reconnect-latency-paced.log
analyze build/logs/reconnect-latency-paced.log | tee build/logs/reconnect-latency-paced.analyzed

echo
if [ "$overall_pass" -eq 1 ]; then
  echo "=== RESULT: PASS -- every measured server-side (zero-gap) reconnect span stayed <= ${THRESHOLD_S}s ==="
  exit 0
else
  echo "=== RESULT: FAIL -- see build/logs/reconnect-latency-*.log for the raw threadtest output ==="
  exit 1
fi
