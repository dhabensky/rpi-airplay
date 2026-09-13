# Comparison against pristine upstream (FDH2/UxPlay tag v1.73.7)

Status: written 2026-09-13. Compares the current baseline (submodule
`d2731a6`, the reverted, regression-tested state — see `PROGRESS.md`'s
2026-09-13 entry) against pristine upstream `FDH2/UxPlay` tag `v1.73.7`,
which is the exact same commit as `df67c21` ("prepations for 1.73.7") —
confirmed via `git merge-base --is-ancestor` and an empty
`git log df67c21..v1.73.7`. Command used throughout:
`git diff df67c21 d2731a6 -- <path>`, run from inside `UxPlay/`.

Overall: `12 files changed, 983 insertions(+), 40 deletions(-)`. Every
file is discussed below; nothing was skipped.

## `lib/raop.c` (11 lines changed) — the most consequential change here

Three `LOGGER_DEBUG` → `LOGGER_INFO` promotions inside `conn_request()`'s
per-new-connection teardown block, one of them with an added warning
comment:

```c
logger_log(raop->logger, LOGGER_INFO, "New AirPlay connection: stopping RAOP audio"
           " service on RAOP connection %p (this closes the just-negotiated audio"
           " UDP sockets -- if this fires right after an AUDIO SETUP response, the"
           " client was told a port that's already been torn down by the time it"
           " sends anything there)", raop_conn);
raop_rtp_stop(raop_rtp);
```

Added in submodule commit `268e168` (2026-09-11), while investigating the
"redundant SETUP reports port 0" bug below. The comment describes a
**separate, never-actually-fixed** failure mode that turned out, on
2026-09-13, to be the leading hypothesis for the currently-open
`bugs/2026-09-13-audio-dies-on-repeated-track-switch-setup.md` — see
`docs/audio-pipeline.md`'s "The `conn_request()` finding" section for the
full mechanism. Upstream has no such warning because upstream's
`conn_request()` is functionally identical here — this is purely a
log-level and comment change, not a behavior change from upstream. The
*behavior* being warned about (unconditional teardown of an existing
`RAOP` connection's audio/mirror/NTP services whenever a new `AIRPLAY`-type
connection is classified) is **upstream's own original behavior**,
unmodified by this fork.

## `lib/raop_handlers.h` (2 lines added)

One new `LOGGER_INFO` line logging the actual `AUDIO SETUP response`
dataPort/controlPort/ct/sr values (`raop_handlers.h:1038`) — diagnostic
only, added in the same `268e168` commit as above. No behavior change.

## `lib/raop_rtp.c` (18 lines changed) — the redundant-SETUP port-0 fix

```c
if (raop_rtp->running || !raop_rtp->joined) {
    /* ... comment ... */
    *control_lport = raop_rtp->control_lport;
    *data_lport = raop_rtp->data_lport;
    MUTEX_UNLOCK(raop_rtp->run_mutex);
    return;
}
```

Upstream's guard left the caller's out-params untouched on this early
return, which — since callers zero-initialize them — echoed port 0 back
to the client on a redundant SETUP. Real, confirmed-on-the-wire bug,
fixed by returning the already-bound ports instead. Two `LOGGER_DEBUG` →
`LOGGER_INFO` promotions alongside it (socket bind confirmation
messages). This is the fix referenced as "bug #3" in project memory.

## `lib/dnssd.c` / `lib/dnssd.h` (34 / 6 lines added)

New `dnssd_reregister()` function. Upstream's only way to refresh mDNS
registration is `unregister_raop/airplay` (which frees `dnssd->name`/
`dnssd->hw_addr` as a side effect once both are unregistered — fine for
upstream's only caller, immediately followed by `dnssd_destroy()`) then
`register_raop/airplay` again. This fork added a periodic refresh (to
recover from avahi dropping externally-registered records on interface
churn, e.g. routine DHCP renewal) that called that exact sequence — a
real use-after-free, crashing the process with `SIGABRT` every ~5 minutes
on the live device. `dnssd_reregister()` does the same
deallocate-then-register steps but *without* the `free()` side effect.
Unrelated to video/audio pipeline threading; a real bug in this fork's
*own* later addition (the periodic refresh caller isn't in this diff —
it's in `uxplay.cpp`, see `dnssd_refresh_callback` below), not upstream.

## `renderers/CMakeLists.txt` (9 lines changed)

Adds `pkg_check_modules(GIO2 REQUIRED gio-2.0)` and links/includes it for
the `renderers` target. Needed because `GFileMonitor` (the overscan
live-config-reload feature) is part of GIO, not transitively pulled in by
`glib-2.0`/`gstreamer-1.0`. Build-system only, no behavior change to
upstream code.

## `tests/test_bus_callback_null_renderer.c` (61 lines, new file)

A unit test added by this fork (not present upstream) for a real crash
class found via crash analysis on real hardware: both
`gstreamer_audio_pipeline_bus_callback` and its video equivalent could
dereference a NULL `renderer` (e.g. a bus watch firing for a
`renderer_type[]` slot that was never made the active `renderer`, or
during teardown). Fixed defensively in both `audio_renderer.c` (see
below) and `video_renderer.c`. This is exactly the kind of autonomous,
hardware-motivated regression test this project already has a pattern
for (`tools/test-*-e2e.sh`).

## `renderers/audio_renderer.c` (59 lines changed) — see `docs/audio-pipeline.md`

Summarized in full there; the changes relative to upstream are:
- `install_av_sync_probe()` call — an autonomous A/V sync self-measurement
  probe (defined in `video_renderer.c`, not audio-specific in origin).
- Audio queue capped at 300ms (`max-size-time=300000000`) instead of
  upstream's default 1s — shortens post-pause drain tail and seek/restart
  resync transients.
- The PTS-rebase-instead-of-drop fix for `ntp < base_time` (a seek/
  reconnect clock jump) — upstream dropped the frame and logged an error;
  this fork re-bases and keeps playing, since dropping was reported as
  making "the sound fly off."
- The **self-heal-on-push-failure** path in `audio_renderer_render_buffer()`
  — upstream's `gst_app_src_push_buffer()` call ignores its return value
  entirely; this fork checks it and calls `audio_renderer_stop()` +
  `audio_renderer_start()` again on failure. See `docs/audio-pipeline.md`
  for why this doesn't fully explain the currently-open bug (it can only
  fire when a push is actually attempted).
- `audio_renderer_flush()` upstream is an **empty function body** — a
  genuine no-op left over in upstream itself (confirmed: the function
  exists and is called, but does nothing). This fork implements it for
  real (`gst_event_new_flush_start`/`flush_stop`), needed so an AirPlay
  FLUSH (seek/pause) actually drops stale buffered audio instead of
  playing it out after the seek.
- The NULL-`renderer` guards in the bus callback (see the test file
  above).

## `renderers/video_renderer.c` (402 lines changed) — largest single diff

Not re-derived line-by-line here (already covered in depth by
`docs/video-pipeline.md` and `docs/framebuffers-and-drm-planes.md`); the
structural additions relative to upstream are:
- `video_renderer_ready` atomic readiness flag (guards `render_buffer()`
  against a half-initialized pipeline).
- The autonomous A/V sync self-measurement probe (`av_sync_probe`/
  `install_av_sync_probe`) — buffer-probe-based, no mic/camera needed;
  unrelated to any bug investigation, a standalone diagnostic capability
  this fork added.
- The overscan compensation feature (`read_overscan_conf`,
  `video_renderer_apply_overscan`) — a deliberate product feature, not a
  bug fix.
- The throwaway-blank-pipeline mechanism (`video_renderer_blank_display`
  + its dedicated thread) for the slow/eventual teardown path — fixes the
  frozen-last-frame-after-disconnect problem in its "eventual" form (see
  `docs/video-pipeline.md`'s state machine).
- The NULL-`renderer` guard in the video bus callback (same class as
  audio's, see the test file above).

The frozen-frame-hide feature (`video_renderer_hide_video()`, the
`force_redraw` thread-safety patch, and everything in submodule commit
`dd95564`) is **not** part of this diff — it was reverted before this
comparison was written (`d2731a6` = pristine `df67c21` content exactly
for the files it touched, confirmed via empty diff in `PROGRESS.md`'s
revert entry).

## `uxplay.cpp` (419 lines changed) — largest file, mostly test infrastructure

The bulk of this diff is the `-capture`/`-replay` autonomous testing
infrastructure this fork built (`cap_write`, `replay_feeder`,
`replay_run`, `replay_do_reconnect`, SPS/PPS re-priming for a simulated
reconnect) — **testing-only code, gated behind `-capture`/`-replay`
command-line flags**, not part of the production request-handling path.
This is what makes `tools/test-reconnect-e2e.sh` and
`tools/test-render-health-e2e.sh` possible at all; upstream has no
equivalent.

Production-path additions:
- `skip_video_rebuild` and the whole fast-path/slow-path split documented
  in `docs/video-pipeline.md`'s state machine.
- The overscan `GFileMonitor` registration and `overscan_config_changed_cb`
  in `main_loop()`.
- `dnssd_refresh_callback` — the periodic mDNS re-registration that
  motivated `dnssd_reregister()` above.

## What this comparison does NOT establish

- It does not prove the `conn_request()` behavior is *wrong* for upstream's
  own intended use case (a single client, single connection-type
  session) — only that this fork's own comment already flagged it as a
  real risk for the specific "audio SETUP followed immediately by a new
  connection" ordering, and that risk appears to match the currently-open
  bug's symptom exactly.
- It does not include a rebuild/behavioral test of pristine `df67c21`
  itself — the comparison is diff-based (reading exactly what changed),
  not empirical (a from-scratch build+flash of stock upstream was judged
  unnecessary given the diffs are small enough to review in full and the
  `conn_request()` code in question is byte-identical to upstream anyway).
