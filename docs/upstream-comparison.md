# Comparison against pristine upstream (FDH2/UxPlay tag v1.73.7)

Status: current, regenerated against submodule commit `f009ad9`. Compares
it against pristine upstream `FDH2/UxPlay` tag `v1.73.7`, which is the
exact same commit as `df67c21` ("prepations for 1.73.7") — confirmed via
`git rev-parse df67c21 v1.73.7` returning identical hashes. Command used
throughout: `git diff df67c21 HEAD -- <path>`, run from inside `UxPlay/`.

Overall: `17 files changed, 1831 insertions(+), 44 deletions(-)`. Every
file is discussed below; nothing was skipped.

## `lib/raop.c` (26 lines changed) — the most consequential change here

`conn_request()`'s per-new-connection teardown block now calls
`raop_should_teardown_existing_connection()` (`lib/raop_conn_policy.h`,
new file, see below) before tearing down an existing `RAOP` connection's
audio/mirror/NTP services, leaving them alone when the new `AIRPLAY`-type
connection is from the same remote address — a track switch or page
refresh in an already-mirroring browser tab looks exactly like this.
Upstream tears down unconditionally. Also three `LOGGER_DEBUG` →
`LOGGER_INFO` promotions in the same block, one with an added comment
warning that stopping RAOP audio here can race a just-negotiated AUDIO
SETUP response.

## `lib/raop_conn_policy.c` / `lib/raop_conn_policy.h` (24 / 50 lines,
new files)

`raop_should_teardown_existing_connection()`: a pure, dependency-free
function (no GStreamer, no `httpd_t`/`raop_t`) comparing raw remote
address bytes, extracted from `conn_request()` specifically so it can be
unit-tested in isolation (`tests/test_raop_conn_policy.c`, see below).
Returns `true` (upstream's original always-teardown behavior) whenever
the inputs don't give a confident "same client" answer — this only
narrows the specific, confidently-identical-address case, never widens
upstream's behavior in any case it doesn't recognize.

## `lib/raop_handlers.h` (2 lines added)

One new `LOGGER_INFO` line logging the actual `AUDIO SETUP response`
dataPort/controlPort/ct/sr values (`raop_handlers.h:1038`) — diagnostic
only, no behavior change.

## `lib/raop_rtp.c` (32 lines changed) — two independent RTP-layer fixes

1. **Redundant-SETUP port-0 fix**: upstream's early-return guard in
   `raop_rtp_start_audio()` left the caller's `control_lport`/
   `data_lport` out-params untouched on a redundant SETUP for an
   already-active stream — since callers zero-initialize them, this
   echoes port 0 back to the client, which silently breaks audio with no
   error anywhere. Fixed by reporting the already-bound ports instead.
2. **RTP-timestamp-to-NTP-time sync-state reset**: `raop_rtp_t` persists
   across every SETUP on a connection, but its sync state
   (`rtp_sync`/`client_ntp_sync`/`initial_sync`) was set once in the
   constructor and never reset. `raop_rtp_start_audio()` now resets all
   three on every (re)start, so a fresh session's RTP timestamp range is
   never combined with a stale sync reference from the previous one. See
   `docs/audio-pipeline.md` for the full mechanism.

Also two `LOGGER_DEBUG` → `LOGGER_INFO` promotions (socket bind
confirmation messages).

## `lib/dnssd.c` / `lib/dnssd.h` (34 / 6 lines added)

New `dnssd_reregister()` function. Upstream's only way to refresh mDNS
registration is `unregister_raop/airplay` (which frees `dnssd->name`/
`dnssd->hw_addr` as a side effect once both are unregistered — fine for
upstream's only caller, immediately followed by `dnssd_destroy()`) then
`register_raop/airplay` again. This fork's periodic refresh (recovering
from avahi dropping externally-registered records on interface churn,
e.g. routine DHCP renewal — see `uxplay.cpp`'s `dnssd_refresh_callback`
below) needs that exact sequence on a timer, which would use-after-free
via that side effect. `dnssd_reregister()` does the same
deallocate-then-register steps but *without* the `free()`.

## `lib/fairplay.h` (8 lines added)

`#ifdef __cplusplus extern "C" { ... } #endif` guard around the function
declarations — every other header in this project has it; this one
didn't, which breaks C++ linkage the moment C++ code (`uxplay.cpp`) calls
these functions directly.

## `renderers/CMakeLists.txt` (9 lines changed)

Adds `pkg_check_modules(GIO2 REQUIRED gio-2.0)` and links/includes it for
the `renderers` target. Needed because `GFileMonitor` (the overscan
live-config-reload feature) is part of GIO, not transitively pulled in by
`glib-2.0`/`gstreamer-1.0`. Build-system only, no behavior change to
upstream code.

## `tests/test_bus_callback_null_renderer.c` (68 lines, new file)

Unit test (not present upstream) for a real crash class: both
`gstreamer_audio_pipeline_bus_callback` and its video equivalent could
dereference a NULL `renderer` (e.g. a bus watch firing for a
`renderer_type[]` slot that was never made the active `renderer`, or
during teardown). Fixed defensively in both `audio_renderer.c` (see
below) and `video_renderer.c`.

## `tests/test_raop_conn_policy.c` (59 lines, new file)

Unit test for `raop_should_teardown_existing_connection()` (see
`lib/raop_conn_policy.c` above) — depends on nothing beyond the one
function under test.

## `renderers/audio_renderer.c` (193 lines changed) / `renderers/audio_renderer.h`
(10 lines added) — see `docs/audio-pipeline.md`

Summarized in full there; relative to upstream:
- Audio queue capped at 300ms (`max-size-time=300000000`) instead of
  upstream's default 1s — shortens post-pause drain tail and seek/restart
  resync transients.
- The PTS-rebase-instead-of-drop fix for `ntp < base_time` (a seek/
  reconnect clock jump) — upstream dropped the frame and logged an error;
  this fork re-bases and keeps playing.
- **Self-heal-on-push-failure** in `audio_renderer_render_buffer()` —
  upstream's `gst_app_src_push_buffer()` call ignores its return value
  entirely; this fork checks it and restarts the audio renderer on
  failure, deferred via `audio_renderer_self_heal_deferred()` (runs on
  the main thread's `GMainLoop`, since this executes on the RAOP audio
  thread while the httpd thread can be calling `audio_renderer_start()`
  concurrently for a new SETUP).
- `audio_renderer_start_deferred()` — same deferral, for the normal
  start path: `audio_get_format()` runs on the httpd thread, and calling
  the synchronous `audio_renderer_start()` there directly would race,
  unsynchronized, against the RAOP audio thread's self-heal path.
- `audio_renderer_flush()` upstream is an **empty function body** — a
  genuine no-op left over in upstream itself. This fork implements it
  for real (`gst_event_new_flush_start`/`flush_stop`), needed so an
  AirPlay FLUSH (seek/pause) actually drops stale buffered audio instead
  of playing it out after the seek.
- The NULL-`renderer` guard in the bus callback (see the test file
  above).
- `install_decode_probe()`/`tt_decode_probe()` — a content-blind
  decode-buffer-count probe on the decoder's src pad, gated behind
  `UX_THREADTEST_DIAG`, used by `-threadtest`/`-ntpresynccheck` (see
  `docs/threadtest.md`). No effect unless that env var is set.

## `renderers/video_renderer.c` (408 lines changed) / `renderers/video_renderer.h`
(1 line added) — largest single diff

Not re-derived line-by-line here (already covered in depth by
`docs/video-pipeline.md` and `docs/framebuffers-and-drm-planes.md`); the
structural additions relative to upstream are:
- `video_renderer_ready` atomic readiness flag (guards `render_buffer()`
  against a half-initialized pipeline).
- The autonomous A/V sync self-measurement probe (`av_sync_probe`/
  `install_av_sync_probe`) — buffer-probe-based, no mic/camera needed;
  a standalone diagnostic capability, unrelated to any specific bug.
- The overscan compensation feature (`read_overscan_conf`,
  `video_renderer_apply_overscan`) — a deliberate product feature, not a
  bug fix; live-reloadable via the `GFileMonitor` set up in
  `uxplay.cpp`'s `main_loop()`.
- The throwaway-blank-pipeline mechanism (`video_renderer_blank_display`
  + its dedicated thread, joined via `video_renderer_join_pending_blank()`
  before the next pipeline init) for the slow/eventual teardown path —
  runs off the main thread so it can't stall time-sensitive protocol
  timers there.
- The NULL-`renderer` guard in the video bus callback (same class as
  audio's, see the test file above).

Note: this fork does **not** currently have any mechanism that visually
hides a frozen last frame on a plain mirror-mode reconnect (the fast
path just leaves the pipeline running with `skip_video_rebuild=true` —
see `docs/video-pipeline.md`'s state machine). An earlier
`video_renderer_hide_video()` feature attempting this was reverted after
causing real regressions; see `docs/video-pipeline.md`'s "Known race
windows" section for that history. It is not part of this diff.

## `uxplay.cpp` (944 lines changed) — largest file, mostly test infrastructure

The bulk of this diff is autonomous testing infrastructure this fork
built, none of it part of the production request-handling path:
- `-capture`/`-replay` (`cap_write`, `replay_run`, `replay_do_reconnect`,
  `extract_sps_pps`, SPS/PPS re-priming for a simulated reconnect) —
  gated behind `-capture`/`-replay` flags. What makes
  `tools/test-reconnect-e2e.sh` and `tools/test-render-health-e2e.sh`
  possible at all; upstream has no equivalent.
- `-threadtest`/`-ntpresynccheck` (`tt_now`, `tt_rtsp_request`,
  `tt_plist_to_bytes`, `tt_send_audio_packet`, `tt_send_sync_packet`,
  `threadtest_driver`, `threadtest_ntp_resync_check`) — a synthetic
  AirPlay client driving the real `raop_init()`/httpd thread/
  `conn_request()`/`raop_handler_setup()`/`raop_rtp_thread_udp` over
  loopback, including a real FairPlay handshake computed offline via
  `lib/fairplay.h`'s functions directly. See `docs/threadtest.md`. Used
  by `tools/test-audio-ntp-resync-e2e.sh` to verify the `raop_rtp.c` fix
  above.

Production-path additions:
- `skip_video_rebuild` and the whole fast-path/slow-path split documented
  in `docs/video-pipeline.md`'s state machine.
- The overscan `GFileMonitor` registration and `overscan_config_changed_cb`
  in `main_loop()`.
- `dnssd_refresh_callback` — the periodic mDNS re-registration that
  motivated `dnssd_reregister()` above (`g_timeout_add_seconds(300, ...)`).
- `audio_renderer_start_deferred()` called from `audio_get_format()`
  instead of the synchronous `audio_renderer_start()` (see
  `renderers/audio_renderer.c` above).

## `.gitignore` (1 line added)

`build*/` glob for local scratch build directories. No behavior change.

## What this comparison does NOT establish

- It does not prove any of `conn_request()`'s, `audio_renderer.c`'s, or
  `video_renderer.c`'s changes are *wrong* for upstream's own intended
  use case — only that they address specific, confirmed-on-real-hardware
  bugs this deployment hit.
- It does not include a rebuild/behavioral test of pristine `df67c21`
  itself — the comparison is diff-based (reading exactly what changed),
  not empirical.
