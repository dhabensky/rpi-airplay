"""Measures the render gap that follows v4l2h264dec's "Received resolution
change" event -- the one normal renegotiation every real AirPlay session
goes through early on (see docs/bugs/2026-09-14-video-render-collapse.md).
A bounded small number of frames (the ordinary cost of the renegotiation
itself) is expected and PASSES; "NEVER" (render never resumes) is the
catastrophic collapse.

Uses tools/captures/resolution-change-gap-repro.cap -- a 1s trim
(tools/trim-capture.py) that deterministically reproduces the event fast.
This is also the fixture used to prove -bt709 (forcing a constant H.264
colorimetry) does NOT meaningfully change the gap size -- see
docs/bugs/2026-09-14-video-render-collapse.md's "Rejected: -bt709"
section. To repeat that comparison: `pytest test_resolution_change_gap.py
--extra-uxplay-args=-bt709` (the `=` matters -- otherwise argparse reads
`-bt709` as another option flag, not this one's value).
"""
from __future__ import annotations

from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
FIXTURE = REPO_ROOT / "tools" / "captures" / "resolution-change-gap-repro.cap"
MAX_GAP_FRAMES = 10  # generous margin over the observed 0-2 frame baseline; catches a real regression, not routine jitter


@pytest.mark.pi_hardware
def test_resolution_change_gap(request, pi_uxplay_deployed, trace_dir):
    from perfetto_trace import Trace

    pi = pi_uxplay_deployed
    extra = request.config.getoption("--extra-uxplay-args")
    remote_cap = "/tmp/resgap-test.cap"
    remote_log = "/tmp/resgap-test.log"
    pi.scp_to(FIXTURE, remote_cap)
    pi.ssh(
        f"GST_DEBUG=kmssink:6,v4l2videodec:5 timeout 15 stdbuf -oL -eL /usr/local/bin/uxplay_debug "
        f"-nohold -vd v4l2h264dec -vc identity -srgb no -n 'Living Room TV' -reset 60 {extra} "
        f"-vs 'kmssink qos=false ts-offset=300000000' "
        f"-as 'alsasink device=plughw:vc4hdmi,0' "
        f"-replay {remote_cap} > {remote_log} 2>&1",
        timeout=30,
    )
    local_log = REPO_ROOT / "build" / "logs" / "resolution-change-gap.log"
    local_log.parent.mkdir(parents=True, exist_ok=True)
    pi.scp_from(remote_log, local_log)
    pi.ssh(f"rm -f {remote_cap} {remote_log}", timeout=15)
    log = local_log.read_text(errors="replace")

    lines = log.splitlines()
    trace = Trace(process_name="resolution-change-gap")
    pending = False
    gap = None
    event_index = 0
    frame_index = 0
    for line in lines:
        if "Received resolution change" in line:
            pending = True
            gap = 0
            trace.add_instant("resolution-change", f"event #{event_index}", frame_index)
            event_index += 1
            continue
        if pending and "Handling frame" in line:
            gap += 1
            frame_index += 1
            continue
        if pending and "gst_kms_sink_import_dmabuf" in line:
            trace.add_instant("resolution-change", f"render resumed (gap={gap})", frame_index)
            pending = False
    trace.write(str(trace_dir / "resolution_change_gap.json"))

    assert gap is not None, f"'Received resolution change' never fired -- fixture or args broke the repro (log: build/logs/resolution-change-gap.log)"
    assert not pending, f"render NEVER resumed after the resolution-change event -- this is the collapse docs/bugs/2026-09-14-video-render-collapse.md describes"
    assert gap <= MAX_GAP_FRAMES, f"gap={gap} frames (limit {MAX_GAP_FRAMES}) -- larger than the observed 0-2 frame baseline"
