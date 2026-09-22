"""Regression check for lib/httpd.c's 8-byte reverse-HTTP peek's
*continuation* path: a request line split across two writes, so the
server's first recv() genuinely returns fewer than 8 bytes, must not
corrupt the parsed protocol string by reading past those bytes -- the
same bug class as test_httpd_short_url_protocol.py, but that test's
`shorturl` mode only exercises the whole-packet (peek_len == 0) path.
Runs tools/synthetic-client.cpp's `shorturlfrag` mode (5 independent
connections; the original corruption was nondeterministic), a genuinely
separate process from the unmodified uxplay_debug under test, in Docker.

To confirm this actually discriminates buggy vs fixed code (this
project's bug-fix protocol, memory: bug_fix_protocol), run this module
against a working tree still on the pre-fix peek_len > 0 branch (8-byte
`peek_buf`, hardcoded `recv_datalen = 8`) -- expect FAIL, corrupted
status line on at least one of the 5 connections -- and against the
current working tree -- expect PASS.
"""
from __future__ import annotations

import re


def test_shorturlfrag_status_line_not_corrupted(two_process_runner, trace_dir):
    log_path = trace_dir.parent / "logs" / "httpd-short-url-frag.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    server_log, client_log = two_process_runner.run("shorturlfrag", client_timeout_s=15.0)
    log = server_log + client_log
    log_path.write_text(log)

    m = re.search(r"SHORTURLFRAG: done total=(\d+) failures=(\d+)", log)
    assert m, f"shorturlfrag client never printed a summary -- see {log_path}\n{log}"
    total, failures = int(m.group(1)), int(m.group(2))
    assert total >= 5, f"expected at least 5 iterations, got {total} -- see {log_path}"
    assert failures == 0, (
        f"{failures}/{total} fragmented-write connections got a corrupted status line "
        f"-- see {log_path}\n{log}"
    )
