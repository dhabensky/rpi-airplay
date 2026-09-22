"""Regression check for lib/httpd.c's 8-byte reverse-HTTP peek: a request
line that completes within the first 8 peeked bytes (e.g. `GET / RTSP/1.0`,
a 1-char URL) must not corrupt the parsed protocol string by reading past
those bytes. Runs tools/synthetic-client.cpp's `shorturl` mode, a genuinely
separate process from the unmodified uxplay_debug under test, in Docker.

To confirm this actually discriminates buggy vs fixed code (this
project's bug-fix protocol, memory: bug_fix_protocol), run this module
twice: once with `--uxplay-ref` pointing at the round-2 working tree
(recv_datalen hardcoded to 8 on every peek pass -- expect FAIL, corrupted
status line), and once with no --uxplay-ref (current working tree --
expect PASS).
"""
from __future__ import annotations

import re


def test_shorturl_status_line_not_corrupted(two_process_runner, trace_dir):
    log_path = trace_dir.parent / "logs" / "httpd-short-url.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    server_log, client_log = two_process_runner.run("shorturl", client_timeout_s=8.0)
    log = server_log + client_log
    log_path.write_text(log)

    m = re.search(r"SHORTURL: recv_len=(\d+) ok=(\d)", log)
    assert m, f"shorturl client never printed a result -- see {log_path}\n{log}"
    ok = m.group(2) == "1"
    assert ok, f"status line corrupted by the 8-byte peek -- see {log_path}\n{log}"
