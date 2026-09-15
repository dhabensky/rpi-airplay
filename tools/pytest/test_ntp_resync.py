"""Regression test for the NTP-sync-state-not-reset-on-restart bug
(UxPlay/lib/raop_rtp.c, see docs/audio-pipeline.md). Runs the scripted
`-ntpresynccheck` driver (uxplay.cpp), which establishes a real session
and sync, restarts it, and sends a probe packet before any new sync
arrives -- asserting the fix's behavior: that packet must be withheld
until a fresh sync arrives, then render with a timestamp consistent with
a later, correctly-synced probe.
"""
from __future__ import annotations

import re


def test_ntp_resync_withholds_stale_probe(docker_runner, trace_dir):
    from perfetto_trace import Trace

    log = docker_runner.run(["-vs", "0", "-ntpresynccheck"], timeout_s=4.0)

    def t(pattern):
        m = re.search(pattern, log)
        return float(m.group(1)) if m else None

    sent_sync2 = t(r"SENT-SYNC-2 t=([\d.]+)")
    renders = re.findall(r"RENDER-BUFFER-CALL t=([\d.]+) seqnum=(\d+) ntp_time=(\d+)", log)
    render_a = next((r for r in renders if r[1] == "1"), None)
    render_b = next((r for r in renders if r[1] == "2"), None)
    assert sent_sync2 is not None and render_a and render_b, f"driver did not complete -- see log:\n{log}"

    render_a_t = float(render_a[0])
    ntp_a, ntp_b = int(render_a[2]), int(render_b[2])
    delta_ns = abs(ntp_b - ntp_a)
    expected_ns = 100 / 44100 * 1e9  # 100 RTP ticks @ 44100Hz
    sane = abs(delta_ns - expected_ns) < 50_000_000  # 50ms tolerance
    rendered_before_sync = render_a_t < sent_sync2

    trace = Trace(process_name="ntp-resync-check")
    trace.add_instant("sync", "SENT-SYNC-2", sent_sync2)
    for t_s, seqnum, ntp_time in renders:
        trace.add_instant("render", f"RENDER-BUFFER-CALL seqnum={seqnum}", float(t_s), {"ntp_time": ntp_time})
    trace.write(str(trace_dir / "ntp_resync.json"))

    assert not rendered_before_sync, (
        f"probe A rendered at t={render_a_t:.4f} BEFORE the second sync (t={sent_sync2:.4f}) -- "
        f"stale sync state wasn't reset on restart"
    )
    assert sane, f"probe A/B ntp_time delta {delta_ns/1e6:.2f}ms, expected ~{expected_ns/1e6:.2f}ms -- inconsistent timestamps"
