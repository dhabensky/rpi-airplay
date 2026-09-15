"""Regression test for the real ~2.8s audio dropout on a lost packet
(docs/bugs/2026-09-14-audio-resume-latency-on-seek.md). Runs the scripted
`-resendstormcheck` driver (uxplay.cpp), which opts into the real
resend-wait path, creates a permanent 3-packet gap, and keeps sending one
audio packet at AAC-ELD's real cadence (~10.9ms) for 3.5s.

To see the bug this guards against: `pytest test_resend_storm.py
--uxplay-ref 59c5dcc` (the commit right before the actual fix, c768aba,
in the UxPlay submodule) -- expect a real FAIL, and the trace's "resend"
track keeps firing while "resolution" never does.
"""
from __future__ import annotations

import re

RESOLVED_THRESHOLD_S = 0.3  # comfortable margin over the observed ~0.10-0.11s fixed, nowhere near ~2.7s unfixed
COUNT_THRESHOLD = 30


def test_resend_storm_resolves_quickly(docker_runner, trace_dir):
    from perfetto_trace import Trace

    log = docker_runner.run(["-vs", "0", "-resendstormcheck"], timeout_s=6.0)

    m_count = re.search(r"RESEND-REQUEST-COUNT (\d+) \(in ([\d.]+)s, sent (\d+) keepalive packets\)", log)
    m_resolved = re.search(r"RESOLVED-AT (-?[\d.]+)", log)
    assert m_count and m_resolved, f"driver did not complete -- see log:\n{log}"

    count, window_s, sent = int(m_count.group(1)), float(m_count.group(2)), int(m_count.group(3))
    resolved_at = float(m_resolved.group(1))

    # The driver only logs two scalars (count, resolved_at) -- no per-request
    # timestamp exists in the real log (checked UxPlay/uxplay.cpp's
    # resendstormcheck loop directly rather than inventing a marker that
    # isn't actually there). The honest, still-visually-obvious artifact:
    # a duration bar from the artificial packet loss (t=0) to resolved_at --
    # wide on buggy code (~2.8s), a sliver on fixed code (~0.1s).
    trace = Trace(process_name="resend-storm-check")
    if resolved_at >= 0:
        trace.add_duration("stall", "unresolved (server still asking for the lost packet)", 0.0, resolved_at, {"resend_request_count": count})
    else:
        trace.add_duration("stall", "NEVER RESOLVED within the window", 0.0, window_s, {"resend_request_count": count})
    trace.add_counter("keepalive", {"sent": sent}, window_s)
    trace.write(str(trace_dir / "resend_storm.json"))

    assert resolved_at >= 0, "never resolved -- no resend-request seen at all (never stopped asking)"
    assert resolved_at <= RESOLVED_THRESHOLD_S, (
        f"stall took {resolved_at:.3f}s to resolve (limit {RESOLVED_THRESHOLD_S}s) -- "
        f"this is the ~2.8s dropout docs/bugs/2026-09-14-audio-resume-latency-on-seek.md describes"
    )
    assert count <= COUNT_THRESHOLD, f"{count} resend requests (limit {COUNT_THRESHOLD}) -- rate-limiting regressed"
