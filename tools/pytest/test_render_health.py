"""Regression test against REAL captured AirPlay sessions -- no Mac, no
live client, no user interaction. Real macOS AirPlay encoding
characteristics for specific client/content combinations can trigger
render-path bugs (see docs/bugs/2026-09-14-video-render-collapse.md)
that synthetic captures never reproduce, so this replays every real
capture in tools/captures/trimmed/ and asserts a healthy render/decode
ratio.

Known limitation, confirmed while writing this suite: `-replay` uses a
single-thread callback-injection model that bypasses the real RTSP/
network layer entirely, and the actual render-collapse bug
(docs/bugs/2026-09-14-video-render-collapse.md) is a timing-dependent
race in that layer -- `--uxplay-ref 51c6fed` (the commit right before
the render-health watchdog fix, on dhabensky-clean-2) against every
capture here still PASSES, confirmed directly. This test's real job is
guarding against the
*other*, non-timing-dependent class of render-rate collapse
(tools/captures/README.md's own original reason for existing: "a real
client's non-native-resolution content triggered a render-rate collapse
that no synthetic capture ever reproduced") -- it just doesn't happen to
be this particular bug. Demonstrating the collapse itself needs a real
live AirPlay session against real hardware; there's no scriptable way to
trigger one (see test_video_reconnect.py's docstring for the same
limitation on a different bug).
"""
from __future__ import annotations

import os
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
# CAPTURES_DIR=tools/captures runs the full-length originals instead of
# the 10s trims (see tools/captures/README.md).
CAPTURES_DIR = Path(os.environ.get("CAPTURES_DIR", REPO_ROOT / "tools" / "captures" / "trimmed"))
MIN_RATIO_PCT = 70
MIN_DECODE_EVENTS = 20  # below this, the capture has essentially no real video (audio-only debugging session)

CAPTURES = sorted(CAPTURES_DIR.glob("*.cap")) if CAPTURES_DIR.is_dir() else []


def _replay_and_parse(pi_uxplay_deployed, cap_path: Path, extra_args: list[str] | None = None):
    pi = pi_uxplay_deployed
    remote_cap = f"/tmp/render-health-{cap_path.stem}.cap"
    remote_log = f"/tmp/render-health-{cap_path.stem}.log"
    pi.scp_to(cap_path, remote_cap)
    args = " ".join(extra_args or [])
    pi.ssh(
        f"GST_DEBUG=kmssink:6,v4l2videodec:5 timeout 30 stdbuf -oL -eL /usr/local/bin/uxplay_debug "
        f"-nohold -vd v4l2h264dec -vc identity -srgb no -n 'Living Room TV' -reset 60 {args} "
        f"-vs 'kmssink qos=false ts-offset=300000000' "
        f"-as 'alsasink device=plughw:vc4hdmi,0' "
        f"-replay {remote_cap} > {remote_log} 2>&1",
        timeout=45,
    )
    local_log = REPO_ROOT / "build" / "logs" / f"render-health-{cap_path.stem}.log"
    local_log.parent.mkdir(parents=True, exist_ok=True)
    pi.scp_from(remote_log, local_log)
    pi.ssh(f"rm -f {remote_cap} {remote_log}", timeout=15)
    return local_log.read_text(errors="replace")


@pytest.mark.pi_hardware
@pytest.mark.parametrize("cap_path", CAPTURES, ids=[c.stem for c in CAPTURES])
def test_render_health(pi_uxplay_deployed, trace_dir, cap_path):
    from perfetto_trace import Trace

    log = _replay_and_parse(pi_uxplay_deployed, cap_path)

    decode_times = [float(m.start()) for m in re.finditer(r"Handling frame", log)]
    render_times = [float(m.start()) for m in re.finditer(r"gst_kms_sink_import_dmabuf", log)]
    decode = len(decode_times)
    render = len(render_times)

    if decode < MIN_DECODE_EVENTS:
        pytest.skip(f"only {decode} decode events -- not enough real video in this capture")

    # No real per-event timestamps survive a log-line-position count (the
    # bash version this replaces didn't extract them either -- it just
    # grep -c'd both markers). Approximate a time axis by line position so
    # the trace still shows the SHAPE of decode vs render over the
    # session (a collapse shows as render's line stopping while decode's
    # keeps climbing), even without real inter-frame timing.
    trace = Trace(process_name=f"render-health:{cap_path.stem}")
    total_lines = log.count("\n") or 1
    d = r = 0
    for i, line in enumerate(log.splitlines()):
        if "Handling frame" in line:
            d += 1
        if "gst_kms_sink_import_dmabuf" in line:
            r += 1
        if "Handling frame" in line or "gst_kms_sink_import_dmabuf" in line:
            trace.add_counter("frames", {"decoded": d, "rendered": r}, i / total_lines)
    trace.write(str(trace_dir / f"render_health_{cap_path.stem}.json"))

    ratio_pct = render * 100 // decode
    assert ratio_pct >= MIN_RATIO_PCT, (
        f"render/decode ratio {ratio_pct}% (render={render} decode={decode}) < required {MIN_RATIO_PCT}% -- "
        f"see build/logs/render-health-{cap_path.stem}.log"
    )
