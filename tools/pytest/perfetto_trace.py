"""Minimal Chrome Trace Event Format writer -- the JSON format Perfetto's
UI (ui.perfetto.dev, drag-and-drop, no server) loads natively, alongside
its own protobuf format. Deliberately not using the protobuf format: it
needs the `perfetto` package and its schema, and nothing these tests need
(a handful of named tracks, counters, instant events) requires it.

Every e2e test in this suite already extracts timestamped, named marker
lines from a log (RENDER-BUFFER-CALL, SENT-SYNC-2, Handling frame N, ...)
-- this module turns that into a trace a reviewer can open and see the
bug (or its absence) directly, instead of reading a log or trusting a
printed PASS/FAIL.

Track model: one counter track per set of related running totals (e.g.
"frames" with "decoded"/"rendered" series -- a collapse shows as one
series flatlining while the other keeps climbing, overlaid in the same
graph) plus one instant-event track per category of discrete marker
(sync packets, resend requests, reconnect boundaries, ...).
"""
from __future__ import annotations

import json
import os


class Trace:
    def __init__(self, process_name: str = "uxplay"):
        self._events: list[dict] = []
        self._pid = 1
        self._tids: dict[str, int] = {}
        self._events.append(
            {"name": "process_name", "ph": "M", "pid": self._pid, "args": {"name": process_name}}
        )

    def _tid(self, track: str) -> int:
        tid = self._tids.get(track)
        if tid is None:
            tid = len(self._tids) + 1
            self._tids[track] = tid
            self._events.append(
                {"name": "thread_name", "ph": "M", "pid": self._pid, "tid": tid, "args": {"name": track}}
            )
        return tid

    def add_counter(self, track: str, series: dict[str, float], ts_seconds: float) -> None:
        """One counter-track sample. `series` may hold multiple named
        values (e.g. {"decoded": 42, "rendered": 40}) rendered as
        overlaid lines on the same track."""
        self._events.append(
            {
                "name": track,
                "ph": "C",
                "pid": self._pid,
                "tid": self._tid(track),
                "ts": round(ts_seconds * 1_000_000),
                "args": series,
            }
        )

    def add_instant(self, track: str, name: str, ts_seconds: float, args: dict | None = None) -> None:
        """A single named marker at a point in time (a sync packet sent,
        a resend request, a reconnect boundary, ...)."""
        self._events.append(
            {
                "name": name,
                "ph": "i",
                "s": "t",
                "pid": self._pid,
                "tid": self._tid(track),
                "ts": round(ts_seconds * 1_000_000),
                "args": args or {},
            }
        )

    def add_duration(self, track: str, name: str, start_s: float, end_s: float, args: dict | None = None) -> None:
        """A named span (e.g. a reconnect gap, a stall window)."""
        tid = self._tid(track)
        self._events.append(
            {"name": name, "ph": "B", "pid": self._pid, "tid": tid, "ts": round(start_s * 1_000_000), "args": args or {}}
        )
        self._events.append(
            {"name": name, "ph": "E", "pid": self._pid, "tid": tid, "ts": round(end_s * 1_000_000)}
        )

    def write(self, path: str) -> None:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w") as f:
            json.dump({"traceEvents": self._events, "displayTimeUnit": "ms"}, f)
