# Per-test reports: status and deletion-candidate flags

One report per `tools/pytest/` test module, each with real revisions
tested, actual FAIL/PASS output, a rendered picture per side, and a
genuine one-time reading of that specific run's data — not a template.
See each `tools/pytest/reports/<module>.md`.

## Status — all 7 done

| Test | Report | Result |
|---|---|---|
| `test_ntp_resync.py` | [test_ntp_resync.md](test_ntp_resync.md) | Real before/after: real bug reproduced, real fix confirmed. |
| `test_resend_storm.py` | [test_resend_storm.md](test_resend_storm.md) | Real before/after: real bug reproduced (2.691s stall), real fix confirmed (0.112s). |
| `test_reconnect_latency.py` | [test_reconnect_latency.md](test_reconnect_latency.md) | No single bug (confirmed) — exploratory, run once for real. |
| `test_video_reconnect.py` | [test_video_reconnect.md](test_video_reconnect.md) | Both before/after PASS — investigated why, found a real reason (see below), not what was expected going in. |
| `test_render_health.py` | [test_render_health.md](test_render_health.md) | Both before/after PASS — structural `-replay` limitation, re-confirmed fresh on `dhabensky-clean`. |
| `test_resolution_change_gap.py` | [test_resolution_change_gap.md](test_resolution_change_gap.md) | Same as `test_render_health.py`. |
| `test_fb0_stays_black.py` | [test_fb0_stays_black.md](test_fb0_stays_black.md) | No ref applies — real reboot, real PASS. |

## Deletion/rework candidates

- **`test_render_health.py` / `test_resolution_change_gap.py`** — real
  regression coverage for *a* class of render-rate collapse, but
  structurally incapable of proving the specific bug
  `docs/bugs/2026-09-14-video-render-collapse.md` describes: `-replay`
  bypasses `lib/httpd.c`/`lib/raop.c` entirely, and that bug is a
  timing-dependent race living specifically in that real-time layer.
  Re-confirmed directly on `dhabensky-clean` this session (not carried
  over from prior work) — all 10 real captures PASS identically at both
  the pre-watchdog and post-watchdog commit. Flagged, not deleted: still
  real coverage for a different render-collapse class; making it capable
  of proving *this* bug needs a client that sends real, re-packetized
  H.264 RTP video instead of `-replay`'s injection model — new protocol
  work, out of scope here.
- **`test_video_reconnect.py`** — the specific before/after commit pair
  (`37c9406`/`29d18d0`) turned out **not** to demonstrate the DRM-master
  race it was chosen for, discovered by actually running it rather than
  trusting commit adjacency: at `37c9406`, an *earlier*, unrelated commit
  (`aa55d16`) had already disabled the `skip_video_rebuild` fast path the
  race lives in, so the "before" run silently exercised the slow
  full-rebuild path instead and passed for an unrelated reason. The test
  mechanism itself is sound (real hardware, real production reconnect
  code path) — the specific commit pair chosen for comparison isn't.
  Rework candidate: needs a commit further back (before `aa55d16`) where
  the fast path is active and the DRM-master fix is genuinely absent, not
  attempted here. Not a deletion candidate — legitimate ongoing
  regression coverage regardless.
- **`test_fb0_stays_black.py`** — legitimate test, different category
  (image-layer boot bug, not `uxplay_debug`) — before/after methodology
  doesn't apply, flagged as such not as a quality problem.
- **`test_reconnect_latency.py`** — legitimate but no single bug to prove
  against by design — flagged as exploratory/no-before-after, not
  deletable but not "proof of a fix" material either.

Nothing here is flagged as an outright deletion candidate. Two tests
(`test_render_health.py`/`test_resolution_change_gap.py`) have a real,
now twice-confirmed structural limitation for one specific bug class;
one (`test_video_reconnect.py`) has a real, freshly-discovered flaw in
its specific before/after evidence (not its mechanism) that needs
follow-up bisection to fix properly.
