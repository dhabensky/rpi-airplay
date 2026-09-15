#!/usr/bin/env python3
"""Trim a -capture .cap file to its first N seconds, at a record boundary.

The .cap format (see UxPlay/uxplay.cpp's cap_write/replay_feeder) is a flat
sequence of records with no header or index -- each is
    [type:1][t:8 LE][ntp:8 LE][len:4 LE][data:len]
and -replay just reads records until EOF, so truncating at any record
boundary produces a valid, shorter capture. Times are real captured
monotonic timestamps (nanoseconds), so trimming by wall-clock duration
(not by byte count or record count) is what actually preserves "the first
N seconds of the session" regardless of the capture's data rate.

Useful for fast, deterministic regression fixtures: most repro-worthy
events (initial codec negotiation, the resolution-change renegotiation
every session goes through, an early resend storm, ...) happen within the
first few seconds -- there's rarely a reason to replay a multi-hundred-MB,
multi-minute capture just to exercise them. See
tools/test-resolution-change-gap-e2e.sh for an example consumer.

Usage: tools/trim-capture.py <src.cap> <dst.cap> <seconds>
"""
import struct
import sys

RECORD_HEADER_FMT = "<cQQi"
RECORD_HEADER_LEN = struct.calcsize(RECORD_HEADER_FMT)


def trim(src_path: str, dst_path: str, seconds: float) -> tuple[int, int]:
    window_ns = int(seconds * 1_000_000_000)
    first_t = None
    n_records = 0
    out_bytes = 0
    with open(src_path, "rb") as f, open(dst_path, "wb") as out:
        while True:
            hdr = f.read(RECORD_HEADER_LEN)
            if len(hdr) < RECORD_HEADER_LEN:
                break
            _type, t, _ntp, length = struct.unpack(RECORD_HEADER_FMT, hdr)
            data = f.read(length) if length > 0 else b""
            if len(data) < length:
                break
            if first_t is None:
                first_t = t
            if (t - first_t) > window_ns:
                break
            out.write(hdr)
            out.write(data)
            out_bytes += len(hdr) + len(data)
            n_records += 1
    return n_records, out_bytes


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    src, dst, secs = sys.argv[1], sys.argv[2], float(sys.argv[3])
    records, size = trim(src, dst, secs)
    print(f"wrote {records} records, {size/1024:.0f} KB covering {secs:.1f}s -> {dst}")
