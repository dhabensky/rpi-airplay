# Real captured AirPlay sessions

Full-length captures in this directory are local scratch, not git-tracked
(`*.cap` in `.gitignore`) -- real `-capture` recordings are 10-150MB+ and
specific to whatever content was mirrored when they were made, not
reproducible artifacts.

**Two subsets of this directory ARE committed** (`.gitignore` carves out
exceptions), because they're small, generic regression fixtures rather
than one-off session dumps:

- `resolution-change-gap-repro.cap` (372KB, ~1s) -- the earliest possible
  trim that still reliably triggers `v4l2h264dec`'s "Received resolution
  change" renegotiation every real session goes through early on.
  Consumed by `tools/pytest/test_resolution_change_gap.py`.
- `trimmed/*.cap` (10s each, ~50MB total) -- one per full-length capture
  ever gathered here, trimmed to their first 10s. Consumed by
  `tools/pytest/test_render_health.py` by default (set
  `CAPTURES_DIR=tools/captures` to use the full-length originals
  instead).

Both were produced with `tools/trim-capture.py <src> <dst> <seconds>`,
which trims at a record boundary using the capture's own real timestamps
(not a byte/record count) -- safe because the `.cap` format has no header
or index, just a flat sequence of self-contained records. Spot-checked
before trusting this as the default: 10s trims measure the same
render/decode ratios as their full-length originals, and the 1s
resolution-change fixture reproduces the exact same gap size as the
39MB capture it came from, deterministically across repeated runs. There
was nothing a multi-minute replay caught that the first several seconds
didn't -- AirPlay's negotiation, and any render-path anomaly triggered by
it, both happen well inside that window.

To add a new full-length capture: enable `-capture <file>.cap` on the
live `uxplay.service` (see `docs/threadtest.md`/`PROGRESS.md` for the
flag), reproduce a real AirPlay mirroring session against whatever
content is relevant, copy the resulting file here (stays gitignored),
then regenerate its trim: `tools/trim-capture.py <file>.cap
trimmed/<name>-10s.cap 10`. Useful specifically for bugs that only
reproduce with real client traffic (see
`tools/pytest/test_render_health.py`'s own module docstring for a
concrete example: a real client's non-native-resolution content
triggered a render-rate collapse that no synthetic capture ever
reproduced).
