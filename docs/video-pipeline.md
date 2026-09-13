# Video pipeline: threading and state machine

Status: reference document, split out 2026-09-13 from the original
combined `video-audio-threading-and-state-machine.md` (see
`docs/README.md` for the full set, including `docs/audio-pipeline.md` and
`docs/framebuffers-and-drm-planes.md`). All facts cited to `file:line` in
the `UxPlay` submodule, re-checked while writing, not recalled from
memory.

This is a **description of what exists**, not a proposal. Where the
architecture is fragile or actively racy, that's called out explicitly in
"Known race windows" below.

## Threads that touch video state

| Thread | Created at | Responsibility |
|---|---|---|
| **Main thread** | (process start) | Runs `main()`'s `reconnect:` loop: calls `main_loop()` (blocks in `g_main_loop_run()`), and on return, conditionally does the full pipeline destroy+rebuild (`uxplay.cpp:3667-3700`). All `GMainLoop` timeout/idle/bus-watch callbacks registered inside `main_loop()` also run here. |
| **httpd thread** | `httpd.c:699`, once, for the process lifetime | The **only** thread that runs `httpd_thread()` (`httpd.c:360`) — a single `select()`-based event loop handling **every** RTSP/HTTP request serially. For video, its relevant duty is the TEARDOWN handler (`raop_handlers.h:1298`/`1314`) calling `video_reset()`. (Its audio-side duties are documented in `docs/audio-pipeline.md`.) |
| **RAOP mirror thread** | `raop_rtp_mirror.c:932`, once per mirror session | Runs `raop_rtp_mirror_thread()` — reads incoming video RTP/H264 data, decrypts, calls `video_set_codec()` (→ `video_renderer_choose_codec()`, `raop_rtp_mirror.c:638,717`) and `video_process()` (→ `video_renderer_render_buffer()`, `uxplay.cpp:2725`). |
| **video-blank thread** (`g_blank_display_thread`) | `video_renderer.c:1200`, ad hoc, joined before the next pipeline init (`video_renderer.c:991-994`) | Legacy "throwaway videotestsrc pipeline" blanking mechanism (`video_renderer.c:965-1042`), used by `video_renderer_destroy()`'s blanking call on a **full** reconnect/teardown. Not used by the 2026-09-12 `video_renderer_hide_video()` (a different, newer mechanism — see below). |

Plus, **not a named thread in this codebase but real**: every GStreamer
element that does async work runs its own internal thread(s) managed by
the framework — `v4l2h264dec`'s decode/output thread (seen directly in
logs: `gstv4l2videodec.c:935:gst_v4l2_video_dec_loop`), and the thread
GStreamer uses internally for `GST_STATE_CHANGE_ASYNC` transitions
(`gst_element_set_state()` returns immediately; the actual work, including
`gst_kms_sink_start()`'s DRM setup, can still be in flight when the
caller's `gst_element_get_state(..., timeout)` returns on timeout rather
than completion).

**`-replay` mode adds a `replay-feeder` thread** (`uxplay.cpp:352`) that
calls the *same* production callbacks (`video_process`, `video_reset`) a
real RAOP mirror thread would — but from a single thread, with no real
network jitter and no real concurrent httpd-thread activity. This is why
`-replay` has repeatedly failed to reproduce threading-timing bugs (see
"Known race windows" below): it collapses several independently-racing
real threads into one, removing the race entirely rather than exercising
it.

## Shared state and what (if anything) protects it

This side of the program has **no dedicated synchronization** of its own.
What exists:

| State | Type | Written from | Read from | Protection |
|---|---|---|---|---|
| `renderer` (module-static in `video_renderer.c:104`) | raw pointer | Main thread (`video_renderer_init/destroy`, `video_renderer.c`), RAOP mirror thread (`video_renderer_choose_codec()`'s `renderer = renderer_used;`, published **last**, `video_renderer.c:1544`) | RAOP mirror thread (`video_renderer_render_buffer()`, `choose_codec()`) | **None.** `video_renderer_render_buffer()` NULL-checks it (`!renderer \|\| !(renderer->appsrc)`, `video_renderer.c:927`) and drops the frame if unset — a deliberate "fail soft," not a race fix; nothing prevents the write and the read from genuinely interleaving. |
| `renderer_type[]` / `n_renderers` (`video_renderer.c:105,113`) | array of pointers / int | Main thread only, inside `video_renderer_init()` (`video_renderer.c:393-540ish`) | RAOP mirror thread (`choose_codec()`, and indirectly via `apply_render_rectangle()`/`video_renderer_apply_overscan()`, which iterate it) | **`video_renderer_ready`** (see below) gates `render_buffer()`'s use of it, but **`choose_codec()` and `apply_render_rectangle()` do not check `video_renderer_ready` at all** — a full reconnect's `video_renderer_destroy()`→`video_renderer_init()` cycle (main thread) can run concurrently with a mirror-thread call into either function with no guard. |
| `video_renderer_ready` (`video_renderer.c:112`) | `volatile gint`, `g_atomic_int_{set,get}` | Main thread, during init/destroy (`video_renderer.c:366,634,654,1177`) | RAOP mirror thread, only inside `render_buffer()` (`video_renderer.c:898`) | **Real** (atomic). But scoped narrowly — protects only the one call site that checks it. |
| `skip_video_rebuild`, `relaunch_video`, `reset_loop`, `reset_httpd`, `full_video_reset`, `preserve_connections` (all `static bool`, `uxplay.cpp:100s-120s`) | plain `bool` | httpd thread (`video_reset()`, called from `raop_handlers.h`'s TEARDOWN/etc. handlers) and RAOP mirror thread (`video_reset()` can also be reached via `audio_stop_coverart_rendering`, itself reachable from the audio path) | Main thread (`reset_callback` every 100ms, `feedback_callback` every 1s, and the post-`main_loop()` relaunch block, `uxplay.cpp:3671-3700`) | **None.** Plain cross-thread bool reads/writes, no atomics, no memory barriers, no compiler ordering guarantees. Works in practice on this platform/compiler today; not something to build further behavior on. |
| kmssink's own `render_rect`, `last_buffer`, `can_scale`, etc. (inside `gst-plugins-bad`, not this codebase) | GStreamer element fields | Whichever thread calls `gst_util_set_object_arg()`/`show_frame()`/`expose()` | Same | `GST_OBJECT_LOCK(self)` **inside kmssink itself** — real, but it's a lock around kmssink's own bookkeeping, not a lock that sequences *when* uxplay's own threads are allowed to call in. It stops the fields from corrupting; it does not stop a call from arriving at a moment this codebase didn't intend (mid-`gst_kms_sink_start()`, mid-async-state-change, etc.) |

**Net effect**: two logically-independent producer threads (httpd thread
for protocol/reset events, RAOP mirror thread for codec/frame data) and
one consumer/owner thread (main thread, via `main_loop()`'s GMainLoop and
the post-loop relaunch block) all read and write the same handful of
globals and the same GStreamer pipeline objects, with real synchronization
existing in exactly one place (`video_renderer_ready`) and nowhere else.

See `docs/framebuffers-and-drm-planes.md` for how kmssink's video overlay
plane (98) relates to the DRM primary plane (86) — directly relevant to
the `HIDDEN` state below.

## Video pipeline state machine (informal — no enum exists in code)

There is no explicit `enum` for this; the following is reconstructed from
the flags above and the transitions they gate.

```
                    video_renderer_init() + video_renderer_start()
                    (main thread, inside the post-main_loop() relaunch
                     block, uxplay.cpp:3679-3690)
                                |
                                v
                  +----------------------------+
                  |  NO_PIPELINE               |
                  +----------------------------+
                                |
                                v
                  +----------------------------+
   choose_codec() |  PLAYING                   | <---------------------+
   restores rect  |  (renderer published,      |                       |
   here (no       |   frames rendering)        |                       |
   expose since   +----------------------------+                       |
   2026-09-13,          |                  |                           |
   see bugs/)           |                  |                           |
                         |                  | RTP_SHUTDOWN (plain       |
                         |                  | disconnect/reconnect/     |
                         |                  | seek-renegotiation --     |
                         |                  | httpd thread, TEARDOWN    |
                         |                  | handler, raop_handlers.h  |
                         |                  | :1298 or :1314)           |
                         |                  v                          |
                         |    +----------------------------+           |
                         |    |  HIDDEN                    |           |
                         |    |  (skip_video_rebuild=true,  |           |
                         |    |   pipeline still alive and  |           |
                         |    |   decoding, render-rectangle|           |
                         |    |   pushed off-screen via     |           |
                         |    |   video_renderer_hide_video,|           |
                         |    |   2026-09-12)                |          |
                         |    +----------------------------+           |
                         |                  |                          |
                         |                  | next connection's        |
                         |                  | choose_codec() call ------+
                         |                  | restores the real rect
                         |
                         | missed_feedback > limit (feedback_callback,
                         | main thread, 1s timer, uxplay.cpp:807-819)
                         | OR close_window/preserve_connections/
                         | full_video_reset set
                         v
           +----------------------------------+
           |  DESTROYED                        |
           |  (video_renderer_destroy(), main   |
           |   thread, throwaway blank pipeline |
           |   painted, then torn down)         |
           +----------------------------------+
                         |
                         v
                video_renderer_init() + video_renderer_start()
                (goto reconnect; back to NO_PIPELINE)
```

Two structurally different "the client went away" paths exist and are
**not the same mechanism**:
- **Fast path** (`skip_video_rebuild=true`): pipeline is kept alive
  (load-bearing for re-mirror — an earlier attempt to always tear down
  broke re-mirroring entirely, see submodule history `1992e08`). Since
  2026-09-12, visually hidden via `video_renderer_hide_video()` instead of
  showing a frozen frame.
- **Slow/eventual path** (`feedback_callback`'s `-reset N` timeout, default
  60s): full `video_renderer_destroy()` + throwaway-blank-pipeline +
  `video_renderer_init()` + `video_renderer_start()`. This is the *only*
  path that existed for blanking before 2026-09-12's fix, and is why that
  fix's own commit message describes the prior state as "not
  instantaneous."

Which path fires for a given "the client seems to have gone" event is
decided independently by two unrelated triggers running on two different
threads/timers: the httpd thread's immediate handling of an explicit
TEARDOWN request, vs. the main thread's 1-second `feedback_callback` poll
noticing missed keepalives. Nothing unifies them into one state
transition table today — they're two separately-evolved code paths that
happen to both eventually affect the same `renderer`/pipeline.

## Known race windows (concrete, already observed — not hypothetical)

Two real bugs traced to this lack of a single owner thread for video
pipeline state (a third, audio-side race is in `docs/audio-pipeline.md`):

1. **`choose_codec()` calling `gst_video_overlay_expose()` right after an
   async `PLAYING` transition it only waited ≤100ms for** — fixed
   2026-09-13, was unconditional in submodule commit `dd95564`.
   `gst_element_get_state(renderer_used->pipeline, ..., 100 *
   GST_MSECOND)` (currently `video_renderer.c:1511`) can return before
   `gst_kms_sink_start()` (running on GStreamer's own state-change thread)
   has actually finished setting up `self->fd`/`self->plane_id`. Calling
   into kmssink's `GstVideoOverlay` interface from the RAOP mirror thread
   at that exact moment is undefined-behavior territory. `-replay`'s
   single-threaded feeding never hit this window; real AirPlay client
   timing did, every time (first-frame-frozen incident). This entire
   feature was later reverted (see `PROGRESS.md`'s 2026-09-13 entry) after
   causing further regressions, so this specific code no longer exists on
   the current baseline — documented here as a real, previously-observed
   failure mode for whenever this area is revisited.

2. **`video_renderer_hide_video()` doing a real, synchronous
   `drmModeSetPlane` + vsync-wait directly inside the httpd thread's
   TEARDOWN response handler** (root-caused in
   `bugs/2026-09-13-audio-resume-latency-after-teardown.md`) — turned a
   previously free `skip_video_rebuild = true;` flag-set into a blocking
   DRM call sitting directly on the client-visible RTSP round-trip,
   because nothing in this codebase distinguishes "cheap, thread-safe to
   do inline" work from "must run on the pipeline's owning thread, defer
   it" work. There is no such distinction anywhere in the code today —
   every call site just calls straight into GStreamer/kmssink from
   whatever thread happens to be running. Also part of the reverted
   feature above; not present on the current baseline.

Both share the same shape: a thread that isn't "the" pipeline-owning
thread reaches directly into pipeline/element state, at a moment nothing
in the code guarantees is safe, because nothing designates who owns that
state or requires callers to hand off to them.

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
