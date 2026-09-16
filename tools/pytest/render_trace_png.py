#!/usr/bin/env python3
"""Renders one perfetto_trace.py JSON trace to a static PNG -- for
dropping into a markdown report (tools/pytest/reports/*.md), where "open
this JSON in ui.perfetto.dev" isn't an option. Generic across every
track type Trace emits: counter tracks become line plots (one line per
series key), instant events become labeled vertical dashed lines,
duration spans become horizontal bars. Not a replacement for the
interactive JSON -- just a static picture of the same data.

Usage: tools/pytest/render_trace_png.py <trace.json> <out.png> [title]
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def render(json_path: str, png_path: str, title: str | None = None) -> None:
    with open(json_path) as f:
        data = json.load(f)
    events = data["traceEvents"]

    tid_names: dict[int, str] = {}
    for e in events:
        if e.get("name") == "thread_name":
            tid_names[e["tid"]] = e["args"]["name"]

    # Timestamps come from CLOCK_MONOTONIC (arbitrary per-boot epoch, e.g.
    # ~118275s of container uptime) -- normalize to the trace's own
    # earliest event so the x-axis actually shows elapsed time, not a
    # meaningless multi-hour offset that squashes every real event into
    # a single pixel.
    all_ts = [e["ts"] for e in events if "ts" in e]
    t0 = min(all_ts) / 1e6 if all_ts else 0.0

    counters: dict[str, dict[str, list[tuple[float, float]]]] = defaultdict(lambda: defaultdict(list))
    instants: dict[str, list[tuple[float, str]]] = defaultdict(list)
    durations: dict[str, list[tuple[float, float, str]]] = defaultdict(list)
    open_durations: dict[tuple[int, str], float] = {}

    for e in events:
        ph = e.get("ph")
        if ph == "C":
            track = tid_names.get(e["tid"], e["name"])
            t = e["ts"] / 1e6 - t0
            for series, value in e["args"].items():
                counters[track][series].append((t, value))
        elif ph == "i":
            track = tid_names.get(e["tid"], e["name"])
            instants[track].append((e["ts"] / 1e6 - t0, e["name"]))
        elif ph == "B":
            open_durations[(e["tid"], e["name"])] = e["ts"] / 1e6 - t0
        elif ph == "E":
            for (tid, name), start in list(open_durations.items()):
                if tid == e["tid"]:
                    track = tid_names.get(tid, name)
                    durations[track].append((start, e["ts"] / 1e6 - t0, name))
                    del open_durations[(tid, name)]
                    break

    tracks = list(dict.fromkeys(list(counters.keys()) + list(instants.keys()) + list(durations.keys())))
    if not tracks:
        raise SystemExit(f"{json_path}: no plottable tracks found")

    fig, axes = plt.subplots(len(tracks), 1, figsize=(10, 2.5 * len(tracks)), squeeze=False)
    axes = [a[0] for a in axes]

    for ax, track in zip(axes, tracks):
        ax.set_title(track, fontsize=10, loc="left")
        if track in counters:
            for series, points in counters[track].items():
                points.sort()
                xs = [p[0] for p in points]
                ys = [p[1] for p in points]
                ax.plot(xs, ys, marker=".", markersize=2, label=series)
            ax.legend(fontsize=8, loc="upper left")
        if track in instants:
            for t, name in instants[track]:
                ax.axvline(t, color="red", linestyle="--", linewidth=1, alpha=0.7)
                ax.annotate(name, (t, 0.5), xycoords=("data", "axes fraction"),
                            rotation=90, fontsize=7, color="red", va="bottom")
        if track in durations:
            for i, (start, end, name) in enumerate(durations[track]):
                ax.barh(i, end - start, left=start, height=0.5, color="orange", alpha=0.7)
                ax.annotate(f"{name} ({end - start:.3f}s)", (start, i), fontsize=8, va="center")
            ax.set_yticks([])
        ax.set_xlabel("t (s, relative)", fontsize=8)
        ax.tick_params(labelsize=8)

    if title:
        fig.suptitle(title, fontsize=12)
    fig.tight_layout()
    fig.savefig(png_path, dpi=120)
    print(f"wrote {png_path}")


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        print(__doc__)
        sys.exit(1)
    render(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None)
