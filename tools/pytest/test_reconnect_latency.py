"""Measures server-side audio TEARDOWN(96)+SETUP(96) reconnect latency
using the real httpd/raop.c stack over loopback -- runs
tools/synthetic-client.cpp's `threadtest` mode, a genuinely separate
process from the unmodified uxplay_debug under test, driving the real
request-handling stack with real RTSP requests entirely in Docker. See
docs/bugs/2026-09-14-audio-resume-latency-on-seek.md for why this
exists: a real capture showed a ~1s reconnect gap on seek, of which
~0.71s is client-paced (not server-controllable) and the rest hit the
cheap same-codec-restart path with nothing slow found. Stress-tests many
more cycles than a single live capture can, hunting for a slow outlier.

-replay cannot do this at all (bypasses lib/httpd.c/lib/raop.c
entirely).
"""
from __future__ import annotations

import re

THRESHOLD_S = 0.5


def _run_threadtest(two_process_runner, n: int, gap_s: float):
    budget_s = 2 + n * (1 + gap_s)
    return two_process_runner.run(
        "threadtest", mode_args=[str(n), "--gap-s", str(gap_s)], client_timeout_s=budget_s,
    )


def _analyze(log: str) -> list[dict]:
    def find_all(pattern):
        return {int(m.group(1)): float(m.group(2)) for m in re.finditer(pattern, log)}

    send_setup = find_all(r"cycle (\d+) SEND-SETUP t=([\d.]+)")
    recv_setup = find_all(r"cycle (\d+) RECV-SETUP-response t=([\d.]+)")
    send_td = find_all(r"cycle (\d+) SEND-TEARDOWN t=([\d.]+)")
    recv_td = find_all(r"cycle (\d+) RECV-TEARDOWN-response t=([\d.]+)")

    first_render: dict[int, float] = {}
    for m in re.finditer(r"RENDER-BUFFER-CALL t=([\d.]+) seqnum=(\d+)", log):
        t, seqnum = float(m.group(1)), int(m.group(2))
        c = seqnum // 1000
        if c not in first_render or t < first_render[c]:
            first_render[c] = t

    cycles = sorted(set(send_setup) & set(recv_setup) & set(send_td) & set(recv_td))
    results = []
    for c in cycles:
        teardown_rt = recv_td[c] - send_td[c]
        setup_rt = recv_setup[c] - send_setup[c]
        nxt = c + 1
        if nxt not in cycles:
            results.append({"cycle": c, "teardown_rt": teardown_rt, "setup_rt": setup_rt, "reconnect_span": None, "note": "N/A (last cycle)"})
        elif nxt not in first_render:
            results.append({"cycle": c, "teardown_rt": teardown_rt, "setup_rt": setup_rt, "reconnect_span": None, "note": "NONE (lost synthetic UDP, not measured latency)"})
        else:
            results.append({"cycle": c, "teardown_rt": teardown_rt, "setup_rt": setup_rt, "reconnect_span": first_render[nxt] - send_td[c], "note": None})
    return results


def test_reconnect_latency_stress(two_process_runner, trace_dir):
    """N=50, zero inter-cycle gap: hunts for a slow outlier across many
    more cycles than one real capture shows."""
    from perfetto_trace import Trace

    log_path = trace_dir.parent / "logs" / "reconnect-latency-stress.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    server_log, client_log = _run_threadtest(two_process_runner, n=50, gap_s=0.0)
    log = server_log + client_log
    log_path.write_text(log)
    results = _analyze(log)
    assert results, f"no cycles measured -- see {log_path}"

    trace = Trace(process_name="reconnect-latency-stress")
    for r in results:
        trace.add_instant("teardown", f"cycle {r['cycle']} teardown", r["teardown_rt"])
        trace.add_instant("setup", f"cycle {r['cycle']} setup", r["setup_rt"])
        if r["reconnect_span"] is not None:
            trace.add_counter("reconnect_span", {"seconds": r["reconnect_span"]}, r["cycle"])
    trace.write(str(trace_dir / "reconnect_latency_stress.json"))

    spans = [r["reconnect_span"] for r in results if r["reconnect_span"] is not None]
    none_count = sum(1 for r in results if r["reconnect_span"] is None and r["note"] and "NONE" in r["note"])
    total = sum(1 for r in results if r["note"] != "N/A (last cycle)")
    if total:
        none_rate = none_count / total
        assert none_rate <= 0.1, (
            f"{none_rate:.0%} of cycles produced no data (lost synthetic UDP) -- too unreliable to trust "
            f"(expected occasional isolated loss under this stress load, not this much)"
        )
    assert spans, f"no cycle produced a measurable reconnect_span -- see {log_path}"
    worst = max(spans)
    assert worst <= THRESHOLD_S, f"worst reconnect_span={worst:.4f}s (limit {THRESHOLD_S}s), mean={sum(spans)/len(spans):.4f}s -- see {log_path}"


def test_reconnect_latency_realistic_pacing(two_process_runner, trace_dir):
    """N=10, 1s inter-cycle gap approximating the real capture's
    client-paced ~0.71s TEARDOWN-to-SETUP gap. Not gated against
    THRESHOLD_S (that gap is client-paced, not server-controllable) --
    exists to sanity-check the stress run's numbers are representative:
    reconnect_span here should land close to (gap + stress run's mean)."""
    from perfetto_trace import Trace

    log_path = trace_dir.parent / "logs" / "reconnect-latency-paced.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    server_log, client_log = _run_threadtest(two_process_runner, n=10, gap_s=1.0)
    log = server_log + client_log
    log_path.write_text(log)
    results = _analyze(log)
    assert results, f"no cycles measured -- see {log_path}"

    trace = Trace(process_name="reconnect-latency-paced")
    for r in results:
        if r["reconnect_span"] is not None:
            trace.add_counter("reconnect_span", {"seconds": r["reconnect_span"]}, r["cycle"])
    trace.write(str(trace_dir / "reconnect_latency_paced.json"))
