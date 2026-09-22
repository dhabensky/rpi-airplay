"""Regression check for lib/httpd.c's single-serial-thread head-of-line-
blocking bug: a connection that sends fewer than 8 bytes then goes silent
must not delay a second, unrelated connection's request behind it. Runs
tools/synthetic-client.cpp's `peekstall` mode, a genuinely separate
process from the unmodified uxplay_debug under test, entirely in Docker.

To confirm this actually discriminates buggy vs fixed code (this
project's bug-fix protocol, memory: bug_fix_protocol), run this module
twice: once with `--uxplay-ref HEAD` (the committed base, before either
of today's httpd.c fixes -- recv() has no timeout at all, so the probe
never gets a response and this test fails), and once with no
--uxplay-ref (the current working tree -- expect PASS).
"""
from __future__ import annotations

import re

THRESHOLD_S = 0.3


def test_peekstall_probe_not_blocked(two_process_runner, trace_dir):
    log_path = trace_dir.parent / "logs" / "httpd-peek-stall.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    server_log, client_log = two_process_runner.run("peekstall", client_timeout_s=8.0)
    log = server_log + client_log
    log_path.write_text(log)

    m = re.search(r"PEEKSTALL: RECV-PROBE t=[\d.]+ elapsed=([\d.]+) ok=(\d)", log)
    assert m, f"peekstall client never printed a RECV-PROBE result -- see {log_path}\n{log}"
    elapsed = float(m.group(1))
    ok = m.group(2) == "1"

    assert ok, f"probe request on the second connection never got a response -- see {log_path}"
    assert elapsed <= THRESHOLD_S, (
        f"probe request took {elapsed:.4f}s (limit {THRESHOLD_S}s) -- the stalled first "
        f"connection's 8-byte peek is head-of-line-blocking the second connection's request; "
        f"see {log_path}"
    )
