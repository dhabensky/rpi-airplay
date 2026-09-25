# Comparison against pristine upstream (FDH2/UxPlay tag v1.73.7)

Generated against submodule commit `08abb3c` ("Add -efifo, a
machine-readable session-event channel"), the tip of the fork branch
`dhabensky-clean-2`. Compared against pristine upstream `FDH2/UxPlay` tag
`v1.73.7`, which is the exact same commit as `df67c21` ("prepations for
1.73.7") — confirmed via `git rev-parse df67c21 v1.73.7` returning
identical hashes, and `git merge-base v1.73.7 08abb3c` returning
`df67c21`, so the fork is a strict linear descendant with no upstream
merges. Commands used throughout, run from inside `UxPlay/`:
`git diff --stat df67c21 HEAD` and `git diff df67c21 HEAD -- <path>`.

Overall: `30 files changed, 3319 insertions(+), 84 deletions(-)` — 13
added files, 17 modified, none deleted or renamed. Every one of those 30
paths has a section below (a few pair a `.c` with its header). **This
audit ages as soon as the submodule pointer moves:** check
`git -C UxPlay rev-parse HEAD` against `08abb3c` above, and if it
differs, re-run `git diff --stat df67c21 HEAD` and reconcile the file
list before trusting any section here.

Line counts in the headings are `git diff --stat`'s totals (insertions
plus deletions) for modified files, and insertion counts for new ones.

## `lib/raop.c` (17 lines changed) — the most consequential change here

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

## `lib/raop_conn_policy.c` / `lib/raop_conn_policy.h` (24 / 32 lines, new files)

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
dataPort/controlPort/ct/sr values — diagnostic only, no behavior change.

## `lib/raop_rtp.c` (15 lines changed) — two independent RTP-layer fixes

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

## `lib/raop_buffer.c` (54 lines changed) — two audio-dropout fixes

Both are generic RAOP-layer behavior, not deployment-specific, and both
add a `CLOCK_MONOTONIC` dependency (`<time.h>`) to a file that had none.

1. **Resend-request rate limit** (`RAOP_RESEND_MIN_INTERVAL_NS`, 100ms):
   upstream's `raop_buffer_handle_resends()` issues a fresh resend
   request for a still-missing packet on every `select()` wakeup, which
   floods the control channel while the gap persists. The limit only
   suppresses repeats for the *same* gap (keyed on `first_seqnum`); a new
   gap always fires immediately.
2. **Stall timeout** (`RAOP_STALL_TIMEOUT_NS`, 200ms): upstream's
   `raop_buffer_dequeue()` will not skip past a missing packet until the
   whole `RAOP_BUFFER_LENGTH` (256-entry) buffer has filled behind it. At
   AAC-ELD's packet cadence that is a multi-second gap in audio. The new
   timeout force-skips a stuck slot once ordinary resend round-trips have
   had a fair chance, independent of remaining capacity. `stalled` is
   deliberately cleared only on a real dequeue, not per force-skip, so a
   multi-packet gap clears in one pass.

Both constants are hardcoded with no CLI flag. They are plausible
upstream candidates — the behavior they fix is not specific to this
hardware — but the exact numbers were tuned against this deployment and
an upstream submission should expect that to be questioned.

## `lib/httpd.c` (86 lines changed) — the peek restructuring

Upstream's `httpd_thread()` runs one serial loop over all connections,
and for each *new* request it enters a captive `while (readstart < 8)`
`recv()` loop to sniff whether the first 8 bytes are a reverse-HTTP
response (`HTTP/1.1` or `EVENT/1.0`) rather than a parseable request.
On a blocking socket with no receive timeout, a client that sends a few
bytes and then goes silent holds that loop — and therefore every other
connection in the same thread — indefinitely. Three changes:

- `httpd_accept_connection()` sets `SO_RCVTIMEO` (5ms) on each accepted
  client socket, bounding every `recv()` in the loop. This follows
  upstream's own idiom for the same call in `lib/raop_ntp.c` and
  `lib/raop_rtp_mirror.c`, including the per-file `CAST` macro those
  files define for Windows.
- The captive loop becomes **one `recv()` attempt per `select()` pass**,
  with per-connection accumulator state on `http_connection_t`
  (`peek_buf`, `peek_len`, `peek_retries_left`) so a fragmented peek
  resumes across passes instead of blocking. `HTTPD_PEEK_MAX_RETRIES`
  (40) bounds a peer that never completes 8 bytes; exceeding it removes
  the connection with a `LOGGER_WARNING` instead of hanging.
- `recv_datalen` is now always `peek_len`, the true accumulated byte
  count, never a hardcoded 8. Upstream's version set `recv_datalen` only
  inside the loop and could hand the parser a length that disagreed with
  what was actually read.

`HTTPD_BUFFER_SIZE` (1024) replaces the bare `char buffer[1024]` and is
shared with `peek_buf`, so a fragmented peek can never be truncated below
what a single whole-packet read would have received.

This is the most invasive structural change to an upstream file in the
fork and **will conflict loudly** on any upstream merge that touches
`httpd_thread()`. Regression coverage:
`tests/test_on_url_protocol_bounds.c` plus `synthetic-client`'s
`peekstall`/`shorturl*` modes (see below).

## `lib/http_request.c` (13 lines changed) — an over-read in `on_url()`

Upstream's `on_url()` does `strncpy(request->protocol, at + length + 1, 8)`,
reading 8 bytes past the URL delimiter with no reference to how many bytes
were actually fed to `http_request_add_data()`. When the request line is
split such that fewer than 8 bytes follow the URL, those bytes come from
whatever is past the end of the caller's buffer. A new `feed_end` field
records one-past-the-end of the current fed buffer and the copy is
clamped to it (and switched to `memcpy`, since the source is not
guaranteed NUL-terminated).

This is a genuine upstream defect, independent of anything in this
deployment, and is the clearest single candidate for upstreaming in the
whole fork.

## `lib/dnssd.c` / `lib/dnssd.h` (21 / 5 lines added)

New `dnssd_reregister()` function. Upstream's only way to refresh mDNS
registration is `unregister_raop/airplay` (which frees `dnssd->name`/
`dnssd->hw_addr` as a side effect once both are unregistered — fine for
upstream's only caller, immediately followed by `dnssd_destroy()`) then
`register_raop/airplay` again. This fork's refresh on address change
(recovering from avahi dropping externally-registered records on
interface churn, e.g. routine DHCP renewal — see `uxplay.cpp`'s
`dnssd_netlink_watch_callback`/`dnssd_refresh_callback` below) needs that
exact sequence repeatedly, which would use-after-free via that side
effect. `dnssd_reregister()` does the same deallocate-then-register steps
but *without* the `free()`.

## `lib/netlink_addr_watch.c` / `lib/netlink_addr_watch.h` (61 / 34)

Two small functions behind the mDNS refresh above:
`netlink_addr_watch_open()` returns a non-blocking `NETLINK_ROUTE` socket
subscribed to `RTMGRP_IPV4_IFADDR`/`RTMGRP_IPV6_IFADDR`, and
`netlink_addr_watch_is_addr_change()` walks one received message batch
looking for `RTM_NEWADDR`/`RTM_DELADDR`. The parser is pure and
dependency-free specifically so it can be unit-tested
(`tests/test_netlink_addr_watch.c`).

Linux-only by construction: the whole implementation is inside
`#ifdef __linux__`, and the non-Linux fallback returns `-1`/`false` so
the caller degrades to the 300-second polling timer. That keeps
upstream's macOS/Windows builds working, but it is a Linux-first feature
in a cross-platform codebase, which upstream would likely weigh against
simply polling everywhere.

## `lib/fairplay.h` (8 lines added)

`#ifdef __cplusplus extern "C" { ... } #endif` guard around the function
declarations — every other header in this project has it; this one
didn't, which breaks C++ linkage the moment C++ code (`uxplay.cpp`, and
now `tools/synthetic-client.cpp`) calls these functions directly. A
trivially upstreamable fix.

## `CMakeLists.txt` (11 lines changed)

Two additions: `event_fifo.c` joins `uxplay.cpp` in the `uxplay`
executable's sources, and a new `synthetic-client` executable is built
from `tools/synthetic-client.cpp` linked against `airplay`. The latter is
deliberately **not** installed — dev/test tooling only, built alongside
`uxplay` so it always matches the library it drives. Build-system only.

Worth knowing on an upstream merge: `synthetic-client` is built
unconditionally, with no `option()` to turn it off, which upstream would
probably want gated.

## `renderers/CMakeLists.txt` (9 lines changed)

Adds `pkg_check_modules(GIO2 REQUIRED gio-2.0)` and links/includes it for
the `renderers` target. Build-system only, no behavior change to upstream
code. See the flag at the end of this document: nothing under
`renderers/` currently references GIO, so this requirement — and its
explanatory comment — appear to have outlived the code that needed them.

## `tests/test_raop_conn_policy.c` (46 lines, new file)

Unit test for `raop_should_teardown_existing_connection()` (see
`lib/raop_conn_policy.c` above) — depends on nothing beyond the one
function under test.

## `tests/test_bus_callback_null_renderer.c` (56 lines, new file)

Unit test (not present upstream) for a real crash class: both
`gstreamer_audio_pipeline_bus_callback` and its video equivalent could
dereference a NULL `renderer` (e.g. a bus watch firing for a
`renderer_type[]` slot that was never made the active `renderer`, or
during teardown). Fixed defensively in both `audio_renderer.c` and
`video_renderer.c` (see below). The test `#include`s
`renderers/audio_renderer.c` directly to reach the file-static
`renderer` and the static bus callback, and stubs `logger_log()` and
`install_av_sync_probe()`.

## `tests/test_netlink_addr_watch.c` (57 lines, new file)

Unit test for `netlink_addr_watch_is_addr_change()`: recognizes
`RTM_NEWADDR`/`RTM_DELADDR`, ignores `RTM_NEWLINK`, walks a mixed batch,
handles zero length. `netlink_addr_watch_open()` is smoke-tested only,
not asserted against a value — an unprivileged container can plausibly
lack netlink, and callers already treat `-1` as "fall back to polling".

## `tests/test_on_url_protocol_bounds.c` (76 lines, new file)

Regression test for the `lib/http_request.c` over-read above. Fills a
buffer with a poison byte (`0x5A`, never a valid protocol-string byte),
copies a prefix of `"GET / RTSP/1.0\r\nCSeq: 1\r\n\r\n"` into it, and
sweeps 14 request-line split points, asserting that `request->protocol`
contains exactly the fed bytes and never a poison byte.

## `tests/test_release_display_epoch_guard.c` (82 lines, new file)

Regression test for `video_renderer_release_display()`'s epoch guard
(see `renderers/video_renderer.c` below). `#include`s
`renderers/video_renderer.c` directly to reach the file-static
`video_connect_epoch` and `video_renderer_release_display_cb()`, and
covers four cases: unchanged epoch hides; bumped epoch suppresses; and
both again through the real public entry point with a real default
`GMainContext` idle dispatch, so the `g_idle_add()` path itself is
exercised rather than reimplemented.

## `tests/test_event_fifo_nonblocking.c` (213 lines, new file)

The largest of the unit tests, for `event_fifo.c` below. It leaves
`SIGALRM`/`SIGPIPE` handlers unset on purpose so a blocking write or a
lost reader kills the test rather than hanging it, and covers: a regular
file at the path being refused; 10,000 begin/end pairs with no consumer
ever attached (the drop path, asserting drops are *logged*); repeated
same-direction transitions collapsing to one line on the wire; a
consumer exiting mid-session and a replacement still receiving later
events; and two threads each emitting 100,000 pairs, with the drained
stream checked for strict `session-begin`/`session-end` alternation to
prove the state test and the write are one critical section.

## `renderers/audio_renderer.c` (138) / `renderers/audio_renderer.h` (6)

Summarized in full in `docs/audio-pipeline.md`; relative to upstream:
- `audio_renderer_init()` gains an `audio_queue_ms` parameter (the
  `-aqueuems` flag) and builds the queue with explicit
  `max-size-buffers=0 max-size-bytes=0 max-size-time=<n>ms`. The default
  is 0 — unbounded, matching the video queue — rather than a baked-in
  site-specific number; the deployment passes its own value if it wants
  one. Upstream's plain `queue !` keeps GStreamer's 1-second default.
- The PTS-rebase-instead-of-drop fix for `ntp < base_time` (a seek/
  reconnect clock jump) — upstream dropped the frame and logged an error;
  this fork re-bases and keeps playing.
- **Self-heal-on-push-failure** in `audio_renderer_render_buffer()` —
  upstream's `gst_app_src_push_buffer()` call ignores its return value
  entirely; this fork checks it and restarts the audio renderer on
  failure, deferred via `audio_renderer_start_deferred(ct, true)` (runs
  on the main thread's `GMainLoop`, since this executes on the RAOP audio
  thread while the httpd thread can be calling `audio_renderer_start()`
  concurrently for a new SETUP).
- `audio_renderer_start_deferred()` — same deferral, for the normal
  start path: `audio_get_format()` runs on the httpd thread, and calling
  the synchronous `audio_renderer_start()` there directly would race,
  unsynchronized, against the RAOP audio thread's self-heal path. The
  `force_restart` flag is packed into the high byte of the `gpointer`
  payload, because a self-heal needs an unconditional stop-then-start
  that `audio_renderer_start()`'s own "same ct" branch will not do.
- `audio_renderer_start()`'s "same codec, repeated SETUP" branch now
  refreshes `gst_audio_pipeline_base_time`, which upstream left stale —
  it has to agree with `raop_rtp.c`'s just-reset sync state.
- `audio_renderer_flush()` upstream is an **empty function body** — a
  genuine no-op left over in upstream itself. This fork implements it
  for real (`gst_event_new_flush_start`/`flush_stop`), needed so an
  AirPlay FLUSH (seek/pause) actually drops stale buffered audio instead
  of playing it out after the seek.
- The NULL-`renderer` guard in the bus callback (see the test file
  above), on both the `appsrc` EOS and the `set_state(READY)` paths.
- `install_decode_probe()`/`tt_decode_probe()` — a content-blind
  decode-buffer-count probe on the decoder's src pad, and a `TT_DIAG`
  macro, both gated behind the `UX_THREADTEST_DIAG` env var and used by
  `synthetic-client`'s `threadtest`/`ntpresync` modes (see
  `docs/threadtest.md`). No output and no cost unless that var is set.

## `renderers/mux_renderer.c` (6 lines changed) — `-mp4` fix

`mux_renderer_choose_audio_codec()` upstream only calls
`mux_renderer_start()` when `audio_ct == 2`, so a mirroring session whose
audio arrives with any other compression type never started the muxer and
produced no output file. Now unconditional, matching the video path in
the same file; `mux_renderer_start()` is idempotent. Generic upstream bug,
nothing deployment-specific — a good upstream candidate. (Its companion
fix, calling `mux_renderer_stop()` from `cleanup()` so the `moov` atom
gets written, is in `uxplay.cpp`.)

## `renderers/video_renderer.c` (389) / `renderers/video_renderer.h` (13)

The largest source diff in the fork, not re-derived line-by-line here
(already covered in depth by `docs/video-pipeline.md` and
`docs/framebuffers-and-drm-planes.md`); the structural additions relative
to upstream are:
- `video_renderer_ready` atomic readiness flag (guards `render_buffer()`
  against a half-initialized pipeline), plus `video_renderer_start()`
  now looping on `gst_element_get_state()` until the state change leaves
  `GST_STATE_CHANGE_ASYNC` instead of accepting one 1-second timeout.
- The autonomous A/V sync self-measurement probe (`av_sync_probe`/
  `install_av_sync_probe`) — buffer-probe-based, no mic/camera needed;
  a standalone diagnostic capability, unrelated to any specific bug,
  opt-in behind the `UX_PROBE` env var because it maps every buffer.
- The render-health probes (`count_buffer_probe`,
  `install_render_health_probes`) and their accessors
  `video_renderer_get_decode_count()`/`_get_render_count()`. Unlike
  `av_sync_probe` these are always on: plain atomic counters on the
  decoder src pad and the sink pad, consumed by `uxplay.cpp`'s
  `render_health_callback`. The decoder is found by `GST_IS_VIDEO_DECODER`
  class check so it works with whatever `-vd` element is in use.
- The overscan compensation feature (`video_renderer_set_overscan`,
  `apply_render_rectangle`, `cached_overscan_rect`) — a deliberate
  product feature, not a bug fix. The library only ever *applies* a fixed
  set of margins to every live mirror-mode `kmssink`'s live-settable
  `render-rectangle` property; where the numbers come from is entirely
  the caller's business (see `-overscan`/`-ofifo` in `uxplay.cpp`).
- `video_renderer_release_display()` and its epoch mechanism
  (`video_connect_epoch`, `video_renderer_release_display_cb`). Hides
  live mirror video by moving it off-screen — a full-size rectangle
  shifted to negative x, because a degenerate `<0,0,1,1>` rect makes
  `gst_video_sink_center_rect()`'s aspect-preserving fit round to <= 0
  and `kmssink` silently skips the DRM commit. No pipeline or element
  state changes, so it is safe from any thread; the real work is
  deferred to the main loop, because doing the `gst_video_overlay_expose()`
  inline on the httpd thread turned a free flag-set into a blocking DRM
  call on the client-visible TEARDOWN round-trip
  (`docs/bugs/2026-09-13-audio-resume-latency-after-teardown.md`). The
  epoch is bumped by `video_renderer_choose_codec()` and checked by the
  deferred callback, so a reconnect that raced ahead of a pending hide
  makes that hide a no-op instead of re-hiding a restored picture.
  Regression-tested by `tests/test_release_display_epoch_guard.c`.
- `video_renderer_blank_primary_plane()` — zeroes `/dev/fb0`, sized from
  `/sys/class/graphics/fb0/`, deferred to the main loop. A plain byte
  write, not a DRM or `kmssink` call: it targets the *primary* plane,
  which this pipeline's `kmssink` never touches, so a non-16:9 source's
  pillarbox margins don't show stale content from whatever drew there
  last. Called from `choose_codec()` on every (re)confirmed PLAYING.
  **This one is specific to this deployment** — see the flag at the end.
- `video_renderer_choose_codec()` restructured: it no longer returns
  early when the requested renderer is already the active one, so a
  same-codec reconnect still re-confirms PLAYING, refreshes `base_time`,
  bumps the epoch, restores the cached overscan rectangle, and blanks the
  primary plane. It also publishes the global `renderer` only after the
  state change is confirmed, and replaces upstream's `g_error()` (which
  aborts the process) on a failed state change with a `LOGGER_ERR` plus
  `-1` return.
- The video queue upstream of the parser gets
  `max-size-buffers=0 max-size-bytes=0 max-size-time=0`; GStreamer's
  defaults could drop a late frame before the decoder ever saw it.
- The NULL-`renderer` guards in the video bus callback (same class as
  audio's, see the test file above), on the ERROR, EOS and
  `autovideo`-sink-name paths.

Note: this fork does **not** currently have any mechanism that visually
hides a frozen last frame on a plain mirror-mode reconnect (the fast
path just leaves the pipeline running with `skip_video_rebuild=true` —
see `docs/video-pipeline.md`'s state machine). An earlier
`video_renderer_hide_video()` feature attempting this was reverted after
causing real regressions; see `docs/video-pipeline.md`'s "Known race
windows" section for that history. It is not part of this diff.

## `event_fifo.c` / `event_fifo.h` (123 / 52 lines, new files)

The outgoing session-event channel behind `-efifo`: one
`session-begin\n` or `session-end\n` line per state transition, so a
consumer can tell when mirroring starts and stops without parsing the
log. Compiled into the `uxplay` executable, not the `airplay` library.
Read `event_fifo.h` for the contract; the parts that matter to a caller:

- **Non-blocking by construction.** The FIFO is created if absent and
  opened `O_RDWR | O_NONBLOCK | O_CLOEXEC`. `O_RDWR` holds the process's
  own reader reference, so there is no `ENXIO` when no consumer is
  attached and no `EPIPE`/`SIGPIPE` when one leaves; a full FIFO gives
  `EAGAIN`, which drops the event. A session never waits on its consumer.
- **A dropped write swallows a later transition.** State only advances
  when the write fully succeeds, and each event is emitted at most once
  per connection with no retry. So a dropped `session-begin` means the
  following `session-end` is suppressed too (the state never changed),
  and the last line a consumer saw can read `session-end` mid-session or
  `session-begin` while idle. Delivered lines always alternate; they are
  not guaranteed to be complete.
- **The write fd is held for the process lifetime** —
  `event_fifo_open()` to `event_fifo_close()`, never reopened. A FIFO
  replaced at that path (deleted and re-created by something else) cannot
  be repaired from the consumer side; the writer keeps writing into the
  old inode. Consumers must not recreate the path.
- A pre-existing non-FIFO at the path is refused with `ENOTSUP` rather
  than accepted: a regular file would absorb every event forever and lose
  the `<= PIPE_BUF` write atomicity the line protocol depends on.
- One mutex covers the state test and the write together, because emits
  come from the main, httpd and RAOP mirror threads.
- `session-end` is prompt on TEARDOWN and on a mirror connection reset,
  but a mirror socket closed with FIN and no TEARDOWN only produces one
  after the missed-feedback timeout (`-reset n`; `MISSED_FEEDBACK_LIMIT`
  is 15 seconds, unchanged from upstream, and this deployment passes
  `-reset 60`). `event_fifo.h`'s own comment states 60 as the default —
  see the flag below.
- `_WIN32` gets stubs: `event_fifo_open()` returns `-1`/`ENOSYS`, emits
  are no-ops.

The mechanism is generic (a path in, two lines out) but it exists for
this deployment's wrapper — `tools/uxplay-menu.c` is the consumer, which
is how the idle menu knows to stop repainting while a client is
connected. Nothing about the *policy* is in the library.

## `tools/synthetic-client.cpp` (1287 lines, new file)

A standalone AirPlay RTSP/RTP client that drives the real `uxplay` server
as a genuinely separate process over loopback, linking `libairplay.a` for
real FairPlay/AES primitives (which is why `lib/fairplay.h` needed its
`extern "C"` guard). It is the only way this fork can exercise real
thread interleaving in the httpd/RAOP path, and per
`docs/verification-protocol.md` it is required acceptance evidence for
pipeline changes, which `-replay` structurally cannot provide. Nine
modes, all selected as `synthetic-client <mode> --port <raop_port>`:

- `threadtest [N]` — N SETUP/audio/TEARDOWN cycles. See
  `docs/threadtest.md`.
- `mirrortest [N]` — N mirror-mode SETUP/video-frames/TEARDOWN cycles,
  the mode that actually reaches the mirror path. Options:
  `--frames-cap PATH` sources real SPS/PPS and a genuinely varying frame
  sequence from a `-capture`-format `.cap` fixture (a repeated single IDR
  masks real decoder behavior); `--frames-per-cycle N` (default 90, ~3s
  at 30fps, 0 = the fixture's full length); `--abort-mirror` closes each
  cycle's mirror data socket with RST rather than FIN, reaching
  `conn_reset(reason 1)`; `--no-teardown` leaves the last cycle's
  connection open with no TEARDOWN or feedback, reproducing a vanished
  client for the implicit-disconnect path; `--idle-s S` then sleeps
  before exiting.
- `ntpresync` — the NTP-sync-reset-on-restart check for `raop_rtp.c`.
- `resendstorm` / `resendrecovery` — the resend-rate and
  recovery-time checks for `raop_buffer.c`.
- `peekstall` — sends fewer than 8 bytes then goes silent; the
  head-of-line-blocking regression check for `lib/httpd.c`.
- `shorturl` / `shorturlfrag [N]` / `shorturlsweep <split> [N]` — the
  peek-truncation and protocol-corruption checks for `lib/httpd.c` and
  `lib/http_request.c`, the last one splitting the request line at a
  caller-chosen byte offset and printing the raw response.

`--host` (default `127.0.0.1`) applies to every mode; `--gap-s` sets the
inter-cycle delay for `threadtest` and `mirrortest`.

## `uxplay.cpp` (467 lines changed) — largest file overall

Test infrastructure, none of it on the production request-handling path:
- `-capture`/`-replay` (`cap_write`, `replay_run`, `replay_feeder`,
  `replay_do_reconnect`, `extract_sps_pps`, SPS/PPS re-priming for a
  simulated reconnect, `UX_RECONNECT_AT_MS`) — gated behind the
  `-capture`/`-replay` flags, which are deliberately absent from
  `print_info()`. What makes `tools/pytest/test_video_reconnect.py` and
  `tools/pytest/test_render_health.py` possible at all; upstream has no
  equivalent. Note the limitation recorded in
  `docs/verification-protocol.md`: `replay_feeder` is a single thread, so
  `-replay` cannot reproduce the interleavings that live in the real
  httpd/RAOP path and is never acceptance evidence on its own.

Production-path additions:
- `skip_video_rebuild` and the whole fast-path/slow-path split documented
  in `docs/video-pipeline.md`'s state machine. `video_reset()`'s
  `RESET_TYPE_RTP_SHUTDOWN` handler now calls
  `video_renderer_release_display()` and sets the flag instead of
  `video_renderer_stop()`, except when `hls_support` is set or connections
  are being preserved.
- `render_health_callback` (1-second timer) plus
  `RENDER_HEALTH_STALL_LIMIT` (3) and the `-norenderhealth` opt-out:
  reads `video_renderer_get_decode_count()`/`_get_render_count()` and
  forces a full video reset when the decoder is producing frames but
  nothing reaches the display for 3 consecutive checks. Only
  decode-without-render counts as the collapse signature; both-idle is
  legitimately static mirrored content, and both-advancing is healthy.
  This recovers faster than `feedback_callback`'s client-silence
  timeout, which would not fire at all if only video were stuck.
- Address-change-driven mDNS refresh: `netlink_addr_watch_open()` plus
  `dnssd_netlink_watch_callback`, with `dnssd_refresh_callback` on a
  300-second timer as the fallback when the kernel has no netlink. Both
  call `dnssd_reregister()` (see `lib/dnssd.c` above).
- `-overscan l:r:t:b` seeds the initial margins before any client
  connects, via `video_renderer_set_overscan()`; `-ofifo <path>` opens a
  FIFO that a wrapper writes `"l r t b\n"` lines to for live updates
  (`overscan_fifo_open_and_watch`, `overscan_fifo_watch_callback`), for
  the process lifetime rather than per-client, so it is tunable whether
  or not anyone is mirroring. `O_RDWR`, not `O_RDONLY`, for the same
  reason `event_fifo.c` uses it: without a writer reference of its own,
  `poll()` returns immediately once the last writer closes and the main
  loop busy-spins.
- `-efifo <path>` opens the event channel (`event_fifo.h` above) once at
  startup. `event_fifo_session_begin()` is emitted from
  `video_set_codec()` (the first mirror codec-config packet);
  `event_fifo_session_end()` from `video_reset()`'s RTP-shutdown path,
  from `conn_reset(reason 1)`, from `feedback_callback`'s missed-feedback
  timeout, and from `cleanup()` so a restart mid-session cannot leave a
  consumer's last event at `session-begin` forever.
- `-aqueuems n` threaded through to `audio_renderer_init()`.
- `audio_renderer_start_deferred()` called from `audio_get_format()`
  instead of the synchronous `audio_renderer_start()` (see
  `renderers/audio_renderer.c` above).
- `audio_set_volume()` now records the real current volume into
  `initial_volume`, so a later `GET_PARAMETER` (or a new connection's own
  initial query) reports what is actually playing instead of the `-vol`
  startup default forever, and clamps `volume` itself on the two
  out-of-range branches that previously clamped only `frac`.
- `cleanup()` calls `mux_renderer_stop()` when `-mp4` is active; without
  it `exit(0)` kills the pipeline before EOS reaches `mp4mux` and the
  `moov` atom never gets written, so the output file is unplayable.
- Includes `<cerrno>` in both branches of the platform `#ifdef`, plus
  `<fcntl.h>` on the non-Windows side, for the FIFO code.

## What is generic and what is ours

For someone merging upstream, the fork splits roughly three ways.

**Generic fixes, no deployment coupling — the upstreaming candidates:**
`lib/http_request.c`'s `on_url()` over-read, `lib/fairplay.h`'s
`extern "C"` guard, `renderers/mux_renderer.c`'s `-mp4` start condition
and `cleanup()`'s `mux_renderer_stop()`, `renderers/audio_renderer.c`'s
empty `audio_renderer_flush()` and ignored `gst_app_src_push_buffer()`
return, `lib/raop_rtp.c`'s port-0 echo on a redundant SETUP, the
NULL-`renderer` bus-callback guards, and `uxplay.cpp`'s stale reported
volume.

**Generic mechanism, this deployment's motivation.** The behavior is not
Pi-specific but the tuning or the trigger came from here:
`lib/httpd.c`'s peek restructuring, `lib/raop_buffer.c`'s two timing
constants, `lib/raop_conn_policy.c`'s same-address exception, the
render-health watchdog, the netlink mDNS refresh, and `-aqueuems`. All
of these keep their numbers as parameters or named constants rather than
site-specific values, and all default to upstream-compatible behavior
where there was a choice.

**Ours, and it shows:**
- `video_renderer_blank_primary_plane()` hardcodes `/dev/fb0` and
  `/sys/class/graphics/fb0/`, and exists only because this deployment
  draws an idle menu on the DRM primary plane while `kmssink` uses an
  overlay (`docs/framebuffers-and-drm-planes.md`). Its own comment says
  it reimplements a deployment script. This is device policy living in
  library code and is the least upstreamable thing in the fork.
- `video_renderer_release_display()` and the epoch mechanism exist for
  the same reason — there is nothing to "release the display" *to* on a
  system without that second plane.
- `-efifo` and `-ofifo` are thin and generic by design (a path in, a
  line protocol out/in; no config-file format, no file watching, no
  policy), but they exist to serve `tools/uxplay-menu.c`. The wrapper
  owns the paths (`/run/uxplay/overscan.fifo`,
  `/run/uxplay-events.fifo`, set in
  `image-builder/files/etc/systemd/system/uxplay.service`), the margin
  values, and what to do with a session event.
- `tools/synthetic-client.cpp` and `-capture`/`-replay` are this
  project's test harness, not a product feature.

## Flags for the next upstream merge

Things a merger should look at, beyond the obvious conflicts:

- **`lib/httpd.c` will conflict loudly.** `httpd_thread()`'s
  new-request peek is restructured, not patched, and upstream's version
  of that loop is gone. Do not resolve this by taking either side
  wholesale; `tests/test_on_url_protocol_bounds.c` and
  `synthetic-client`'s `peekstall`/`shorturl*` modes are the arbiters.
- **`renderers/CMakeLists.txt`'s GIO requirement looks obsolete.**
  Nothing under `renderers/` references `gio`, `g_file*` or `GFile*` at
  `08abb3c` — verified with `git grep -n "gio\|g_file\|GFile" 08abb3c
  -- renderers/`, whose only hits are the `pkg_check_modules` line itself
  and its comment. The comment attributes the dependency to
  `GFileMonitor` for live overscan reload, but that mechanism was
  replaced by `-ofifo`'s `GIOChannel` (which is GLib, not GIO). Not
  changed here — this is a docs-only task — but it is a `REQUIRED`
  build-time dependency that may no longer buy anything, and the comment
  describing it is stale.
- **`uxplay.cpp`'s overscan-FIFO comment names a script that no longer
  exists.** `overscan_fifo_open_and_watch()`'s comment cites
  `uxplay-overscan-sync` as the measured case for `O_RDWR`; that script
  was removed from `image-builder/` when the menu and overscan units were
  collapsed into `uxplay-menu`. The `O_RDWR` rationale itself still
  holds for any one-shot writer, but naming a wrapper-repo script inside
  the upstream-shared source tree is exactly the coupling this project
  tries to avoid.
- **Seven new CLI flags, none in the man page.** `-overscan`, `-ofifo`,
  `-efifo`, `-aqueuems`, `-norenderhealth`, `-capture` and `-replay` are
  parsed in `parse_arguments()`; the first five are in `print_info()`
  and `-capture`/`-replay` are intentionally hidden. `uxplay.1`,
  `README.md`, `README.txt` and `README.html` are untouched, and upstream
  documents every option in all of them. Any upstream submission needs
  those four files updated.
- **`synthetic-client`'s `mirrortest` default `--frames-cap` points
  outside the repository** —
  `tools/captures/trimmed/personalmac-stall-20260911-10s.cap`. No `.cap`
  fixture is tracked in the fork (`git ls-tree -r --name-only 08abb3c`
  has no match for `captures` or `*.cap`), so the default only resolves
  in a working tree that has this deployment's local captures. Callers
  must pass `--frames-cap` explicitly anywhere else.
- **`event_fifo.h` documents this deployment's `-reset` value as the
  library default.** Its `event_fifo_session_end()` comment says
  `"-reset n" seconds, default 60`; `MISSED_FEEDBACK_LIMIT` in
  `uxplay.cpp` is 15 in both the fork and upstream, and 60 is what
  `uxplay.service` passes. A wrong number in a library header, and a
  deployment value at that.
- **`tools/synthetic-client.cpp`'s file header still says
  "Audio-only."** — stale since `mirrortest` was added.
- **`synthetic-client` is built unconditionally** by the top-level
  `CMakeLists.txt`, with no `option()` to disable it. Fine here, likely
  not acceptable upstream.

## What this comparison does NOT establish

- It does not prove any of `conn_request()`'s, `audio_renderer.c`'s,
  `video_renderer.c`'s or `httpd.c`'s changes are *wrong* for upstream's
  own intended use case — only that they address specific,
  confirmed-on-real-hardware bugs this deployment hit.
- It does not include a rebuild or behavioral test of pristine `df67c21`
  itself, or of `08abb3c`. The comparison is diff-based (reading exactly
  what changed), not empirical: every claim here about *why* a change
  exists comes from the code, its comments and the linked bug write-ups,
  not from a measurement taken while writing this document.
- It does not audit the fork's 33 individual commits, only the net diff
  against upstream. A change made and later reverted within the fork's
  own history leaves no trace here (`video_renderer_hide_video()` above
  is one such case, called out only because it is easy to look for and
  not find).
