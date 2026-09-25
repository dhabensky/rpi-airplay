# Video pipeline: threading and state machine

Status: reference document (see `docs/README.md` for the full set,
including `docs/audio-pipeline.md` and `docs/framebuffers-and-drm-
planes.md`). Checked against submodule commit `08abb3c`.

Citations name a **file plus a symbol or flag**, never a line number:
line numbers drift silently, whereas a symbol that has been renamed or
deleted fails a `git -C UxPlay grep` and the staleness is visible.

This is a **description of what exists**, not a proposal. Where the
architecture is fragile or actively racy, that's called out explicitly in
"Known race windows" below.

## Threads that touch video state

| Thread | Created at | Responsibility |
|---|---|---|
| **Main thread** | (process start) | Runs `main()`'s `reconnect:` loop: calls `main_loop()` (blocks in `g_main_loop_run()`), and on return, conditionally does the full pipeline destroy+rebuild (`uxplay.cpp`, the block after `main_loop()` guarded by `relaunch_video`). All `GMainLoop` timeout/idle/bus-watch callbacks registered inside `main_loop()` also run here, including every `g_idle_add()` body the other threads defer onto it. |
| **httpd thread** | `httpd.c`'s `httpd_start()`, once, for the process lifetime | The **only** thread that runs `httpd_thread()` (`httpd.c`) — a single `select()`-based event loop handling **every** RTSP/HTTP request serially. For video, its relevant duty is `raop_handler_teardown()` (`raop_handlers.h`) calling `video_reset()` with `RESET_TYPE_RTP_SHUTDOWN`. (Its audio-side duties are documented in `docs/audio-pipeline.md`.) |
| **RAOP mirror thread** | `raop_rtp_mirror.c`, `THREAD_CREATE(... raop_rtp_mirror_thread ...)`, once per mirror session | Runs `raop_rtp_mirror_thread()` — reads incoming video RTP/H264 data, decrypts, calls the `video_set_codec` callback (→ `video_renderer_choose_codec()`) and `video_process` (→ `video_renderer_render_buffer()`, both wired up in `uxplay.cpp`). |

Plus, **not a named thread in this codebase but real**: every GStreamer
element that does async work runs its own internal thread(s) managed by
the framework — `v4l2h264dec`'s decode/output thread (seen directly in
logs: `gstv4l2videodec.c:935:gst_v4l2_video_dec_loop`), and the thread
GStreamer uses internally for `GST_STATE_CHANGE_ASYNC` transitions
(`gst_element_set_state()` returns immediately; the actual work, including
`gst_kms_sink_start()`'s DRM setup, can still be in flight when the
caller's `gst_element_get_state(..., timeout)` returns on timeout rather
than completion).

**`-replay` mode adds a `replay-feeder` thread** (`uxplay.cpp`'s
`replay_feeder()`, driving `replay_loop`) that
calls the *same* production callbacks (`video_process`, `video_reset`) a
real RAOP mirror thread would — but from a single thread, with no real
network jitter and no real concurrent httpd-thread activity. This is why
`-replay` has repeatedly failed to reproduce threading-timing bugs (see
"Known race windows" below): it collapses several independently-racing
real threads into one, removing the race entirely rather than exercising
it.

## Shared state and what (if anything) protects it

There is **no lock** anywhere on this side of the program — only two
atomic flags and a deferral convention. What exists:

| State | Type | Written from | Read from | Protection |
|---|---|---|---|---|
| `renderer` (module-static in `video_renderer.c`) | raw pointer | Main thread (`video_renderer_init()`/`video_renderer_destroy()`), RAOP mirror thread (`video_renderer_choose_codec()`'s `renderer = renderer_used;`, published **last**) | RAOP mirror thread (`video_renderer_render_buffer()`, `video_renderer_choose_codec()`) | **None.** `video_renderer_render_buffer()` NULL-checks it (`!renderer \|\| !(renderer->appsrc)`) and drops the frame if unset — a deliberate "fail soft," not a race fix; nothing prevents the write and the read from genuinely interleaving. |
| `renderer_type[]` / `n_renderers` (`video_renderer.c`) | array of pointers / int | Main thread only, inside `video_renderer_init()` | RAOP mirror thread (`video_renderer_choose_codec()`, and indirectly via `apply_render_rectangle()`, which iterates it for every live pipeline) | **`video_renderer_ready`** (see below) gates `video_renderer_render_buffer()`'s use of it, but **`video_renderer_choose_codec()` and `apply_render_rectangle()` do not check `video_renderer_ready` at all** — a full reconnect's `video_renderer_destroy()`→`video_renderer_init()` cycle (main thread) can run concurrently with a mirror-thread call into either function with no guard. |
| `video_renderer_ready` (`video_renderer.c`) | `gint`, `g_atomic_int_{set,get}` | Main thread, during `video_renderer_init()`/`video_renderer_start()`/`video_renderer_destroy()` | RAOP mirror thread, only inside `video_renderer_render_buffer()` | **Real** (atomic). But scoped narrowly — protects only the one call site that checks it. |
| `video_connect_epoch` (`video_renderer.c`) | `gint`, `g_atomic_int_{inc,get}` | RAOP mirror thread, in `video_renderer_choose_codec()` on every (re)confirmed `PLAYING` | Main thread, in `video_renderer_release_display_cb()` | **Real** (atomic). Read at scheduling time and re-read in the deferred callback: a reconnect that raced ahead bumps the epoch, so the stale hide no-ops instead of blanking a restored picture. |
| `cached_overscan_rect`, `cached_screen_w`/`_h` (`video_renderer.c`) | `char[64]` / int | Main thread, in `video_renderer_set_overscan()` (driven by `-overscan` at startup and by `-ofifo` lines afterwards) | RAOP mirror thread via `video_renderer_choose_codec()`, main thread via `video_renderer_release_display_cb()` | **None.** Small fixed-size buffers written and read without a lock; the write is a whole-string `snprintf()` and the reads only ever hand the result to kmssink, so a torn read costs one wrong `render-rectangle` until the next apply. |
| `skip_video_rebuild`, `relaunch_video`, `reset_loop`, `reset_httpd`, `full_video_reset`, `preserve_connections` (all `static bool` in `uxplay.cpp`) | plain `bool` | httpd thread (`video_reset()`, called from `raop_handler_teardown()` and the other `raop_handlers.h` handlers) and RAOP mirror thread (`video_reset()` can also be reached via `audio_stop_coverart_rendering`, itself reachable from the audio path) | Main thread (`reset_callback` every 100ms, `feedback_callback` and `render_health_callback` every 1s, and the post-`main_loop()` relaunch block) | **None.** Plain cross-thread bool reads/writes, no atomics, no memory barriers, no compiler ordering guarantees. Works in practice on this platform/compiler today; not something to build further behavior on. |
| kmssink's own `render_rect`, `last_buffer`, `can_scale`, etc. (inside `gst-plugins-bad`, not this codebase) | GStreamer element fields | Whichever thread calls `gst_util_set_object_arg()`/`show_frame()`/`expose()` | Same | `GST_OBJECT_LOCK(self)` **inside kmssink itself** — real, but it's a lock around kmssink's own bookkeeping, not a lock that sequences *when* uxplay's own threads are allowed to call in. It stops the fields from corrupting; it does not stop a call from arriving at a moment this codebase didn't intend (mid-`gst_kms_sink_start()`, mid-async-state-change, etc.) |

**Net effect**: two logically-independent producer threads (httpd thread
for protocol/reset events, RAOP mirror thread for codec/frame data) and
one consumer/owner thread (main thread, via `main_loop()`'s GMainLoop and
the post-loop relaunch block) all read and write the same handful of
globals and the same GStreamer pipeline objects, with real synchronization
existing in exactly two places (`video_renderer_ready`,
`video_connect_epoch`) and nowhere else.

See `docs/framebuffers-and-drm-planes.md` for how kmssink's video overlay
plane (98) relates to the DRM primary plane (86) — relevant whenever
plane 98 doesn't cover the full screen (e.g. pillarbox margins for
non-16:9 content).

## Video pipeline state machine (informal — no enum exists in code)

There is no explicit `enum` for this; the following is reconstructed from
the flags above and the transitions they gate.

```
                    video_renderer_init() + video_renderer_start()
                    (main thread, in the post-main_loop() relaunch block)
                                |
                                v
                  +----------------------------+
                  |  NO_PIPELINE               |
                  +----------------------------+
                                |
                                v
                  +-----------------------------+
   choose_codec() |  PLAYING                    | <--------------------+
   bumps the      |  (renderer published,       |                      |
   epoch, restores|   frames rendering)         |                      |
   the rect, and  +-----------------------------+                      |
   blanks fb0           |                  |                           |
                        |                  | RESET_TYPE_RTP_SHUTDOWN   |
                        |                  | (plain disconnect /       |
                        |                  | reconnect / seek          |
                        |                  | renegotiation -- httpd    |
                        |                  | thread, video_reset()     |
                        |                  | from raop_handler_        |
                        |                  | teardown())               |
                        |                  v                           |
                        |    +-----------------------------+           |
                        |    |  HIDDEN                     |           |
                        |    |  (skip_video_rebuild=true + |           |
                        |    |   video_renderer_release_    |           |
                        |    |   display(): pipeline alive, |           |
                        |    |   render-rectangle moved off |           |
                        |    |   screen so the idle menu on |           |
                        |    |   plane 86 shows through)    |           |
                        |    +-----------------------------+           |
                        |                  |                           |
                        |                  | next connection's         |
                        |                  | choose_codec() -----------+
                        |                  | restores cached_overscan_rect
                        |
                        | missed_feedback > missed_feedback_limit
                        | (feedback_callback, main thread, 1s timer)
                        | OR render_health_callback sees
                        | RENDER_HEALTH_STALL_LIMIT consecutive seconds
                        | of decode-without-render
                        | OR close_window/preserve_connections/
                        | full_video_reset set
                        v
           +----------------------------------+
           |  DESTROYED                        |
           |  (video_renderer_destroy(), main  |
           |   thread: every renderer_type[]   |
           |   pipeline dropped to NULL)       |
           +----------------------------------+
                         |
                         v
                video_renderer_init() + video_renderer_start()
                (goto reconnect; back to NO_PIPELINE)
```

Two structurally different "the client went away" paths exist and are
**not the same mechanism**:
- **Fast path**: `skip_video_rebuild = true` plus a call to
  `video_renderer_release_display()`. The pipeline is kept alive —
  load-bearing for re-mirror, since tearing it down instead breaks
  re-mirroring entirely — and the frozen last frame is hidden by moving
  kmssink's `render-rectangle` fully off the left edge, not by touching
  pipeline state. The next connection's
  `video_renderer_choose_codec()` restores `cached_overscan_rect`.
- **Slow/eventual path**: full `video_renderer_destroy()` +
  `video_renderer_init()` + `video_renderer_start()`, triggered by
  `feedback_callback`'s `missed_feedback_limit` (`-reset n`, upstream
  default `MISSED_FEEDBACK_LIMIT` = 15s; `uxplay.service` passes
  `-reset 60`) or by `render_health_callback`'s decode-without-render
  watchdog. The only path that does a full pipeline teardown, hence "slow."

Which path fires for a given "the client seems to have gone" event is
decided independently by three unrelated triggers on two different
threads/timers: the httpd thread's immediate handling of an explicit
TEARDOWN request, vs. the main thread's 1-second `feedback_callback` and
`render_health_callback` polls. Nothing unifies them into one state
transition table today — they're separately-evolved code paths that
happen to both eventually affect the same `renderer`/pipeline.

## Deferring work onto the main thread

Two video entry points are callable from any thread and defer their real
work with `g_idle_add()` rather than doing it inline:

- `video_renderer_release_display()` → `video_renderer_release_display_cb()`
  — hides video on disconnect. Epoch-guarded via `video_connect_epoch`.
- `video_renderer_blank_primary_plane()` → `blank_primary_plane_cb()` —
  zeroes `/dev/fb0` when a connection (re)confirms `PLAYING`, so stale
  primary-plane content can't bleed through a non-16:9 source's pillarbox
  margins. A plain byte write, not a DRM call; see
  `docs/framebuffers-and-drm-planes.md`.

Under `-replay` these land on `replay_loop` instead of `main_loop()`'s
loop, which is the one structural difference `-replay` preserves here.

## Known race windows

Live on the current baseline:

1. **`video_renderer_choose_codec()` runs on the RAOP mirror thread and is
   not gated by `video_renderer_ready`.** It calls
   `gst_element_set_state(..., GST_STATE_PLAYING)` and then
   `gst_element_get_state(..., 100 * GST_MSECOND)`, which can return on
   timeout rather than completion while `gst_kms_sink_start()` is still
   setting up DRM on GStreamer's own state-change thread. Its
   `apply_render_rectangle(cached_overscan_rect, FALSE)` sets a GObject
   property only — no `gst_video_overlay_expose()` on this path, which is
   deliberate — so the window is narrower than it was, but a concurrent
   main-thread `video_renderer_destroy()`→`video_renderer_init()` is still
   unsynchronized against it.

2. **`apply_render_rectangle()` is reachable from two threads.** The RAOP
   mirror thread reaches it via `video_renderer_choose_codec()`; the main
   thread reaches it via `video_renderer_set_overscan()` and
   `video_renderer_release_display_cb()`. It iterates `renderer_type[]` and
   calls `gst_bin_get_by_name()` per pipeline, with no lock.

Both share the same shape: a thread that isn't "the" pipeline-owning
thread reaches directly into pipeline/element state, at a moment nothing
in the code guarantees is safe, because nothing designates who owns that
state or requires callers to hand off to them.

### History: what the deferral mechanism exists to prevent

Kept because these two failures are the reason
`video_renderer_release_display()` defers instead of acting inline.
Neither construct is on this branch: `video_renderer_hide_video()` does not
exist at all, and `video_renderer_choose_codec()` no longer calls
`gst_video_overlay_expose()` (the only caller left is
`apply_render_rectangle()`'s `force_redraw` branch).

- A `gst_video_overlay_expose()` call in `video_renderer_choose_codec()`
  right after the ≤100ms `PLAYING` wait produced a permanently frozen
  first frame against real client timing, every time, while `-replay`'s
  single-threaded feeding never hit the window. Reverted; see
  `docs/archive/PROGRESS-2026-09-13--2026-09-19.md`.
- A `video_renderer_hide_video()` doing a synchronous `drmModeSetPlane` +
  vsync-wait inline in the httpd thread's TEARDOWN handler put a blocking
  DRM call on the client-visible RTSP round-trip — root-caused in
  `bugs/2026-09-13-audio-resume-latency-after-teardown.md`. Its
  replacement, `video_renderer_release_display()`, sets a property from an
  epoch-guarded main-thread idle callback instead.

## What's NOT covered by this document

- Exact GStreamer-internal threading (how many threads `v4l2h264dec`/
  `kmssink` themselves spin up, and their own locking) — treated as an
  opaque, correctly-synchronized-internally dependency; only the
  *boundary* (what `uxplay.cpp`/`video_renderer.c` call into them, from
  which thread) is in scope here.
- HLS/coverart-playback pipeline paths (`playbin`/`playbin3`) — mentioned
  only where they intersect the mirror-mode code paths above.
- Audio: see `docs/audio-pipeline.md`.
- DRM plane/framebuffer detail: see `docs/framebuffers-and-drm-planes.md`.
