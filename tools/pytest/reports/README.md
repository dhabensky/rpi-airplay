# Per-test reports: status and deletion-candidate flags

One report per `tools/pytest/` test module, each with real revisions
tested, actual FAIL/PASS output, a rendered picture per side, and a
genuine one-time reading of that specific run's data — not a template.
See each `tools/pytest/reports/<module>.md`.

## Status

| Test | Report | Status |
|---|---|---|
| `test_ntp_resync.py` | [test_ntp_resync.md](test_ntp_resync.md) | **Done.** Real before/after, real bug reproduced and fixed. |
| `test_resend_storm.py` | [test_resend_storm.md](test_resend_storm.md) | **Done.** Real before/after, real bug reproduced and fixed. |
| `test_reconnect_latency.py` | [test_reconnect_latency.md](test_reconnect_latency.md) | **Done.** No single bug (confirmed, not assumed) — exploratory, run once for real. |
| `test_render_health.py` | — | **Pending.** Needs the real Pi (`v4l2h264dec`/`kmssink`, hardware-specific) — unreachable this session. Architectural finding from earlier work (see below) still needs re-confirming on `dhabensky-clean` specifically before it goes in a report. |
| `test_resolution_change_gap.py` | — | **Pending.** Same reason as `test_render_health.py`. |
| `test_video_reconnect.py` | — | **Pending.** Needs the real Pi. Commit pair already identified and both binaries pre-built (`37c9406` before / `29d18d0` after, unchanged real historical commits — see `docs/bugs/...`), ready to run once the Pi is reachable. |
| `test_fb0_stays_black.py` | — | **Pending.** Needs a real reboot of the Pi. No `uxplay_debug` ref applies (image-builder bug, not the binary) — nothing to pre-build. |

## Deletion/rework candidates (flagged now, from work already done)

- **`test_render_health.py` / `test_resolution_change_gap.py`** — real
  regression coverage for *a* class of render-rate collapse, but
  structurally incapable of proving the specific bug
  `docs/bugs/2026-09-14-video-render-collapse.md` describes:
  `-replay` uses a single-thread callback-injection model that bypasses
  `lib/httpd.c`/`lib/raop.c` entirely, and that bug is a timing-dependent
  race living specifically in that real-time layer. Confirmed directly in
  earlier work (not assumed): running every capture in
  `tools/captures/trimmed/` against a pre-render-health-watchdog binary
  still PASSED, regardless of which binary replayed it. **This finding
  needs to be re-run against `dhabensky-clean`'s specific commit pair
  before it's re-asserted in a report** (scheduled for this evening,
  alongside the rest of the Pi-dependent work) — flagged here as a
  known, architecturally-grounded limitation in the meantime, not a fresh
  claim.
- **`test_fb0_stays_black.py`** — legitimate test, different category
  from every other one here (image-layer boot bug, not a `uxplay_debug`
  behavior) — the before/after-commit methodology this report format is
  built around doesn't apply to it at all. Not a quality problem, just a
  different kind of test; will be reported as such once run.
- **`test_reconnect_latency.py`** — legitimate, but no single bug to
  prove against by design (see its own report). Not a deletion candidate,
  but not "proof of a fix" material either — an ongoing outlier-hunting
  stress test, reported as exactly that.

Nothing here is flagged as an outright deletion candidate — every test's
either confirmed useful with real evidence, or has an honest, specific,
non-vague reason its usefulness is limited in a particular way.
