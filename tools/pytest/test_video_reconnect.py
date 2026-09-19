"""End-to-end test for the video reconnect path (skip_video_rebuild /
video_reset(RESET_TYPE_RTP_SHUTDOWN)) against REAL Pi hardware -- no Mac,
no AirPlay client, no UI automation. Exists because this exact class of
bug (the v4l2h264dec hardware decoder firmware wedging on pipeline
destroy+recreate, see uxplay.cpp's skip_video_rebuild comment) is
hardware-specific and can only be reproduced/caught on the real device,
and because there's no scriptable way to trigger a real AirPlay mirror
session (see tools/make-synthetic-cap.py's header for why).

Synthesizes a valid .cap from a locally-generated H.264 test pattern
(tools/make-synthetic-cap.py), deploys it, runs -replay with
UX_RECONNECT_AT_MS set to fire partway through (drives the real
production reconnect code path), with GST_DEBUG=kmssink:6. Verification: count kmssink's
gst_kms_sink_import_dmabuf log lines (one per actually-rendered frame)
before vs after the simulated reconnect -- a wedged decoder shows render
activity stop dead after reconnect while the feeder keeps accepting
input.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import uuid
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DURATION_S = 24
RECONNECT_AT_S = 12
MIN_RENDERS_AFTER = 10


@pytest.mark.pi_hardware
def test_video_survives_a_reconnect(pi_uxplay_deployed, trace_dir):
    from perfetto_trace import Trace

    pi = pi_uxplay_deployed
    # NOT pytest's own tmp_path: that resolves under macOS's system tmpdir
    # (/private/var/folders/...), which colima's Docker VM does not share
    # in -- a bind mount onto it silently produces an empty view inside
    # the container (confirmed the hard way while writing the original
    # bash version of this test). build/ is this project's own
    # established Docker-shared scratch area.
    tmp_path = REPO_ROOT / "build" / f"reconnect-test-{uuid.uuid4().hex[:8]}"
    tmp_path.mkdir(parents=True)
    try:
        h264_path = tmp_path / "test.h264"
        cap_path = tmp_path / "test.cap"

        subprocess.run(
            [
                "docker", "run", "--rm", "-v", f"{tmp_path}:/out", "debian:trixie-slim", "bash", "-c",
                "apt-get update -qq >/dev/null 2>&1 && "
                "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg >/dev/null 2>&1 && "
                f"ffmpeg -y -f lavfi -i 'testsrc=size=640x480:rate=10:duration={DURATION_S}' "
                "-c:v libx264 -profile:v baseline -pix_fmt yuv420p "
                "-x264-params keyint=10:scenecut=0 -f h264 /out/test.h264",
            ],
            check=True, capture_output=True,
        )
        subprocess.run(
            [sys.executable, str(REPO_ROOT / "tools" / "make-synthetic-cap.py"), str(h264_path), str(cap_path), "10"],
            check=True, capture_output=True,
        )

        remote_cap = "/tmp/test-reconnect.cap"
        remote_log = "/tmp/test-reconnect.log"
        pi.scp_to(cap_path, remote_cap)
        reconnect_ms = RECONNECT_AT_S * 1000
        pi.ssh(
            f"GST_DEBUG=kmssink:6 UX_RECONNECT_AT_MS={reconnect_ms} "
            f"stdbuf -oL -eL /usr/local/bin/uxplay_debug "
            f"-nohold -vd v4l2h264dec -vc identity -srgb no -n 'Living Room TV' -reset 60 "
            f"-vs 'kmssink qos=false ts-offset=300000000' "
            f"-as 'alsasink device=plughw:vc4hdmi,0' "
            f"-replay {remote_cap} > {remote_log} 2>&1",
            timeout=DURATION_S + 20,
        )
        local_log = REPO_ROOT / "build" / "logs" / "video-reconnect.log"
        local_log.parent.mkdir(parents=True, exist_ok=True)
        pi.scp_from(remote_log, local_log)
        pi.ssh(f"rm -f {remote_cap} {remote_log}", timeout=15)
        lines = local_log.read_text(errors="replace").splitlines()

        reconnect_idx = next((i for i, l in enumerate(lines) if "RECONNECT DONE" in l), None)
        assert reconnect_idx is not None, f"'RECONNECT DONE' never appeared -- reconnect simulation didn't fire (see {local_log})"

        before = sum(1 for l in lines[:reconnect_idx] if "gst_kms_sink_import_dmabuf" in l)
        after = sum(1 for l in lines[reconnect_idx:] if "gst_kms_sink_import_dmabuf" in l)

        trace = Trace(process_name="video-reconnect")
        trace.add_instant("reconnect", "RECONNECT DONE", reconnect_idx)
        r = 0
        for i, l in enumerate(lines):
            if "gst_kms_sink_import_dmabuf" in l:
                r += 1
                trace.add_counter("renders", {"count": r}, i)
        trace.write(str(trace_dir / "video_reconnect.json"))

        assert after >= MIN_RENDERS_AFTER, (
            f"kmssink rendered only {after} frames after the simulated reconnect (before: {before}) -- "
            f"signature of the v4l2h264dec wedging bug (pipeline destroy+recreate leaves the decoder "
            f"firmware stuck). See {local_log}"
        )
    finally:
        shutil.rmtree(tmp_path, ignore_errors=True)
