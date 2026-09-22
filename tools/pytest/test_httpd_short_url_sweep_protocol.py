"""Regression check for lib/http_request.c's on_url(): a request line split
inside "RTSP/1.0"'s 8-byte protocol window must yield only a clean, exact
prefix of it -- never leaked memory from a prior connection.
"""
from __future__ import annotations

import re

import pytest

# Splits inside "RTSP/1.0"'s 8-byte span, where httpd.c's peek buffer already
# reaches the 8-byte threshold before on_url() sees the rest.
SWEEP_SPLITS = [8, 9, 10, 11, 12, 13]


@pytest.mark.parametrize("split", SWEEP_SPLITS)
def test_shorturlsweep_status_line_not_corrupted(two_process_runner, trace_dir, split):
    log_path = trace_dir.parent / "logs" / f"httpd-short-url-sweep-{split}.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    server_log, client_log = two_process_runner.run(
        "shorturlsweep", mode_args=[str(split), "5"], client_timeout_s=15.0
    )
    log = server_log + client_log
    log_path.write_text(log)

    m = re.search(rf"SHORTURLSWEEP\[split={split}\]: done total=(\d+) failures=(\d+)", log)
    assert m, f"shorturlsweep client never printed a summary -- see {log_path}\n{log}"
    total, failures = int(m.group(1)), int(m.group(2))
    assert total >= 5, f"expected at least 5 iterations, got {total} -- see {log_path}"
    assert failures == 0, (
        f"{failures}/{total} split={split} connections got a status line that wasn't an "
        f"exact prefix of \"RTSP/1.0\" -- see {log_path}\n{log}"
    )
