# UxPlay video/audio threading and state machine (as currently built)

Status: **first draft, for review**. Written 2026-09-13 after three
consecutive same-night regressions (frozen first frame, dead audio,
audio-resume latency) that each looked fixed in isolation but kept
reopening a neighboring problem — the direct cause was making changes
without a map of who touches what, from which thread, under what (if any)
lock. This document is that map. All facts below are cited to
`file:line` in the `UxPlay` submodule and were re-checked while writing
this, not recalled from memory.

This is a **description of what exists**, not a proposal. Where the
architecture is fragile or actively racy, that's called out explicitly in
section 6, but no fix is proposed here — see the fork this document sets up
in the "Where this leaves us" section at the end.

## 1. Threads

Six threads are explicitly created (`grep -rn "THREAD_CREATE\|g_thread_new"`),
plus GStreamer's own internal threads and the process's main thread:

| Thread | Created at | Responsibility |
|---|---|---|
| **Main thread** | (process start) | Runs `main()`'s `reconnect:` loop: calls `main_loop()` (blocks in `g_main_loop_run()`), and on return, conditionally does the full pipeline destroy+rebuild (`uxplay.cpp:3667-3700`). All `GMainLoop` timeout/idle/bus-watch callbacks registered inside `main_loop()` also run here, since they're dispatched by the loop this thread drives. |
| **httpd thread** | `httpd.c:699`, once, for the process lifetime | The **only** thread that runs `httpd_thread()` (`httpd.c:360`) — a single `select()`-based event loop handling **every** RTSP/HTTP connection and request serially (SETUP, TEARDOWN, RECORD, GET/SET_PARAMETER, ...). Dispatches into `raop_handlers.h`'s per-request-type handlers. **Also touches the audio GStreamer pipeline directly**: the SETUP handler for an audio stream (`raop_handlers.h:1027`) calls `audio_get_format()` → `audio_renderer_start()` (`uxplay.cpp:2851`) inline, in the very same request handler that also calls `raop_rtp_start_audio()` — see section 5. |
| **RAOP mirror thread** | `raop_rtp_mirror.c:932`, once per mirror session | Runs `raop_rtp_mirror_thread()` — reads incoming video RTP/H264 data, decrypts, calls `video_set_codec()` (→ `video_renderer_choose_codec()`, `raop_rtp_mirror.c:638,717`) and `video_process()` (→ `video_renderer_render_buffer()`, `uxplay.cpp:2725`). |
| **RAOP audio thread** | `raop_rtp.c:705`, (re)created per `raop_rtp_start_audio()` call | Runs `raop_rtp_thread_udp()` — reads incoming audio RTP, decrypts, calls `audio_process()` (→ `audio_renderer_render_buffer()`, `raop_rtp.c:631`) and, via `raop_rtp_process_events()`, `audio_set_volume`/`audio_flush` (`raop_rtp.c:314-322`) — i.e. this thread owns essentially all per-buffer audio rendering calls except `audio_renderer_start()` itself (see above). Exits when `raop_rtp->running` goes false (`raop_rtp.c:270-273`); a **redundant SETUP while this thread has already exited** re-creates it from scratch with fresh ports (`raop_rtp.c:664`, guard only fires if `running \|\| !joined`) — this is the mechanism behind the 2026-09-13 "audio dies after a burst of repeated SETUP" bug (`bugs/2026-09-13-audio-dies-on-repeated-track-switch-setup.md`, still open). |
| **RAOP NTP thread** | `raop_ntp.c:437` | Clock sync only; not relevant to rendering state. |
| **video-blank thread** (`g_blank_display_thread`) | `video_renderer.c:1200`, ad hoc, joined before the next pipeline init (`video_renderer.c:991-994`) | Legacy "throwaway videotestsrc pipeline" blanking mechanism (`video_renderer.c:965-1042`), used by `video_renderer_destroy()`'s blanking call on a **full** reconnect/teardown. Not used by tonight's `video_renderer_hide_video()` (a different, newer mechanism — see below). |

Plus, **not separately listed above but real**: every GStreamer element
that does async work runs its own internal thread(s) managed by the
framework — `v4l2h264dec`'s decode/output thread (seen directly in logs:
`gstv4l2videodec.c:935:gst_v4l2_video_dec_loop`), and the thread GStreamer
uses internally for `GST_STATE_CHANGE_ASYNC` transitions
(`gst_element_set_state()` returns immediately; the actual work,
including `gst_kms_sink_start()`'s DRM setup, can still be in flight when
the caller's `gst_element_get_state(..., timeout)` returns on timeout
rather than completion).

**`-replay` mode adds a `replay-feeder` thread** (`uxplay.cpp:352`) that
calls the *same* production callbacks (`video_process`/`audio_process`,
`video_reset`) a real RAOP mirror/audio thread would — but from a single
thread, with no real network jitter and no real concurrent httpd-thread
activity. This is why `-replay` has repeatedly failed to reproduce
threading-timing bugs this session (see section 6): it collapses several
independently-racing real threads into one, removing the race entirely
rather than exercising it.

## 2. Shared state and what (if anything) protects it

The video-rendering side of this program has **no dedicated
synchronization** of its own. What exists:

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

## 3. Framebuffers and DRM planes

This system's SoC (Broadcom VC4, `vc4-kms-v3d` DRM/KMS driver) exposes
dozens of DRM planes (`tools/drmdump.c` enumerates all of them: 43, 62,
74, 86, 98, 109, 120, ... up to 659 on this hardware) — standard for an
atomic-KMS driver offering multiple overlay/cursor planes per CRTC. **Only
two are ever actually driven by this project**, and understanding both —
and which is which — is what section 4's `HIDDEN` state and the
2026-09-12/13 boot-console-text bugs (PROGRESS.md) both turn on.

### Plane 86 — the primary plane

- Always full-screen (`CRTC_X=0 CRTC_Y=0 CRTC_W=1920 CRTC_H=1080`,
  confirmed via `drmdump` every time it's been checked this project).
- Backed by `/dev/fb0` — the kernel's legacy fbdev interface. Confirmed
  empirically, not assumed: raw bytes read from `/dev/fb0` and converted
  to a PNG matched, pixel for pixel, what was actually showing through on
  this plane (2026-09-13, during the boot-console-text investigation).
- **Owned by the kernel's `fbcon` driver, not by uxplay or GStreamer at
  all.** fbcon writes two independent things onto it:
  1. Kernel/systemd boot console *text*, whenever a `console=` kernel
     cmdline parameter routes output to this tty (fixed 2026-09-13 by
     removing `console=tty1` from `cmdline.txt` — see
     `image-builder/customize-boot.sh`).
  2. A blinking VT cursor, unconditionally, regardless of whether any text
     is routed there — independent bug, needed its own fix
     (`vt.global_cursor_default=0`, same commit).
- Zeroed **once**, early in boot, by `/usr/local/bin/zero-fb0`
  (`uxplay.service`'s `ExecStartPre`). This is a one-shot mitigation, not
  a standing guarantee — nothing re-zeros it if fbcon writes to it again
  later. That gap (systemd kept printing boot messages to console for a
  while *after* `zero-fb0` already ran) was the actual root cause of the
  2026-09-13 "boot log visible again" regression, not a flaw in
  `zero-fb0` itself.
- The **throwaway blank-pipeline mechanism** (`video_renderer.c:1023`,
  `videotestsrc pattern=black num-buffers=1 ! kmssink
  force-modesetting=true`, used by the `DESTROYED` path in section 4) also
  ultimately paints onto this plane (`force-modesetting=true` forces a
  full CRTC modeset, which targets the primary plane) — a real rendered
  black frame via a fresh, temporary kmssink, not a `/dev/fb0` write. This
  is a *different* mechanism from `zero-fb0` that happens to affect the
  same plane; don't confuse the two when debugging.

### Plane 98 — the video overlay plane

- What `kmssink` actually renders decoded mirror-mode video onto (h264 and
  h265 share this in practice, since only one codec is ever active per
  session).
- Geometry is fully dynamic, driven live by kmssink's `render-rectangle`
  property — the **same mechanism** backs both the overscan feature
  (inset margins) and the frozen-frame-hide feature (pushed off-screen via
  a large negative X, see `video_renderer_hide_video()`).
- Composites **on top of** the primary plane wherever it covers it
  (standard DRM overlay-plane stacking) — the primary plane is never
  actually invisible, just normally fully covered.

### Why this matters (the actual bug-class connection)

Wherever plane 98 does **not** cover the full screen — either because the
mirrored content genuinely isn't 16:9 (pillarbox margins) or because
`video_renderer_hide_video()` deliberately pushed it off-screen (`HIDDEN`
state, section 4) — **plane 86's content shows through in the gap**, and
plane 86's content is governed entirely by the kernel's fbcon, a subsystem
this codebase has no direct runtime control over beyond the one-shot
`zero-fb0` script and the two kernel-cmdline flags above. This is why
"pillarbox margins show boot text instead of black" and "screen after
disconnect shows boot text instead of black" (reported as two separate-
feeling complaints, 2026-09-13) were actually the exact same root cause.

**Tooling note**: `tools/drmdump.c` reads both planes' live atomic
properties *and* dumps their actual pixel content — this is the only
reliable way to verify what's really composited on screen. Reading
`/dev/fb0` alone only ever shows plane 86's content in isolation, never
the real composited result once plane 98 is active; an earlier point in
this project's history wrongly assumed `/dev/fb0` was fully decoupled from
real scanout, which this fact disproves — see
[[verify_visible_outcome_not_mechanism]].

**Not investigated**: whether the many idle planes (43, 62, 74, 109, 120,
... 659) are reserved for anything specific (a cursor plane, a second
CRTC's own primary/overlay pair) — irrelevant to a single-HDMI-output
deployment like this one, so left unresolved rather than assumed.

## 4. Video pipeline state machine (informal — no enum exists in code)

There is no explicit `enum` for this; the following is reconstructed from
the flags in section 2 and the transitions they gate.

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

## 5. Audio pipeline

Structurally simpler than video (no DRM planes, no overscan/hide
mechanism, no `HIDDEN` state) but with its own two-thread hazard that
directly matters for the currently-open
`bugs/2026-09-13-audio-dies-on-repeated-track-switch-setup.md`
investigation. All facts below are from `renderers/audio_renderer.c`
(482 lines, read in full) and the same `lib/raop_rtp.c` /
`lib/raop_handlers.h` call sites already cited in sections 1 and 4.

### Two separate "audio" state machines, easy to conflate

This codebase actually has **two independent audio lifecycles**, owned
by different files and different threads, that only interact indirectly:

1. **The RTP-receiving layer** (`lib/raop_rtp.c`): a UDP socket pair +
   `raop_rtp_thread_udp()` thread, tracked by `raop_rtp->running`/`joined`.
   This is what a "SETUP" request creates or reuses (`raop_rtp_start_audio()`,
   section 1's table). It only knows about encrypted RTP packets on the
   wire — nothing about GStreamer.
2. **The GStreamer rendering layer** (`renderers/audio_renderer.c`): the
   module-static `renderer` pointer + per-format pipelines, built once at
   startup and switched between by `audio_renderer_start()`. This is what
   actually decodes and plays sound.

A SETUP request's handler (httpd thread, `raop_handlers.h:1027` on)
touches **both**, in sequence, in the same function: `audio_get_format()`
(→ `audio_renderer_start()`, layer 2) first, then `raop_rtp_start_audio()`
(layer 1). They are two separate calls with no shared lock between them,
into two separately-synchronized (or unsynchronized) subsystems.

### GStreamer pipeline construction (per format)

`audio_renderer_init()` (`audio_renderer.c:131`, called once at startup,
main thread) builds **one static `gst_parse_launch()` pipeline per audio
format** (`NFORMATS = 2` in practice — AAC-ELD and ALAC; PCM/AAC-LC exist
in the array but are never seen from a real client) and keeps all of them
alive for the process lifetime in `renderer_type[]`:

```
appsrc name=audio_source
  ! queue max-size-time=300000000 (300ms cap, non-leaky)
  ! avdec_aac | avdec_alac   (format-specific decoder, if the plugin's present)
  ! audioconvert
  ! audioresample quality=10
  ! volume name=volume
  ! level
  ! <audiosink>  (alsasink in production, sync=true/false depending on -av/-as)
```

`renderer` (module-static, `audio_renderer.c:56`) points at whichever of
`renderer_type[]`'s pre-built pipelines is currently active; switching
formats mid-session tears the old one down to `GST_STATE_NULL` and starts
the new one (`audio_renderer_start()`, `audio_renderer.c:293`) — but for a
**same-format** repeat call (exactly what a repeated SETUP for the same
AAC-ELD stream is), the function does **nothing at all**: `if (id >= 0 &&
renderer) { if (*ct != renderer->ct) { ...rebuild... } }` — same format
means the inner rebuild never runs, so the GStreamer pipeline itself is
untouched by a same-format redundant SETUP. Whatever breaks in the
open audio-dies bug therefore isn't a GStreamer pipeline rebuild race on
its own — see the next subsection for what else is possible.

### State/protection table (audio-specific rows, same format as section 2)

| State | Type | Written from | Read from | Protection |
|---|---|---|---|---|
| `renderer` (`audio_renderer.c:56`) | raw pointer | httpd thread (`audio_renderer_start()`) **and** RAOP audio thread (`audio_renderer_render_buffer()`'s self-heal path, see below, calls `audio_renderer_stop()`+`audio_renderer_start()` again) | RAOP audio thread (`audio_renderer_render_buffer()`, `audio_renderer_set_volume()`, `audio_renderer_flush()`) | **None.** Unlike video's `renderer` (written by exactly one non-main thread), audio's `renderer` can be written by **two different threads** — httpd thread on every SETUP, RAOP audio thread on every self-heal — with no lock, no atomic, nothing. |
| `gst_audio_pipeline_base_time` (`audio_renderer.c:34`) | `GstClockTime` | Same two threads, same two call sites | RAOP audio thread (`audio_renderer_render_buffer()`'s PTS-rebase logic, `audio_renderer.c:322-333`) | **None.** |
| `render_audio`, `sync` (`audio_renderer.c:42,45`) | plain `gboolean` | httpd thread, inside `get_renderer_type()` (`audio_renderer.c:257`, called from `audio_renderer_start()`) | RAOP audio thread (`audio_renderer_render_buffer()`'s very first line gates on `render_audio`) | **None.** |

### The race this points at for bug #10

`audio_renderer_render_buffer()` (RAOP audio thread, called once per
incoming audio packet — i.e. constantly, the hottest of these call sites)
has its own **self-heal-on-failure** path (`audio_renderer.c:377-397`):
if `gst_app_src_push_buffer()` returns anything other than
`GST_FLOW_OK` (the comment there says this used to fail completely
silently before this self-heal existed), it calls `audio_renderer_stop()`
then `audio_renderer_start()` **itself, from the RAOP audio thread** —
touching exactly the same `renderer` pointer and the exact same GStreamer
pipeline state transitions (`gst_app_src_end_of_stream`,
`gst_element_set_state`) that the **httpd thread** can be doing at the
same moment for a concurrently-arriving SETUP request.

Neither call site takes any lock. If a burst of rapid repeated SETUPs
(the bug's trigger) causes the httpd thread to call `audio_renderer_start()`
around the same time the RAOP audio thread's self-heal path decides to
call `audio_renderer_stop()`/`audio_renderer_start()` on its own (plausible
if the repeated SETUP/TEARDOWN churn on the `raop_rtp.c` layer disrupts
timing enough to trip the self-heal condition), both threads could be
tearing down and rebuilding the *same* `renderer`/pipeline concurrently —
a direct analogue of section 4's video races, not yet confirmed as the
actual cause (that needs the clean debug capture named in the bug's "Next
diagnostic step"), but now a concrete, code-grounded hypothesis to check
for, in addition to the `raop_rtp.c`-layer `joined`/`running` question
already documented there.

## 6. Known race windows (concrete, already observed — not hypothetical)

Three real bugs, all from the same night, all traced to this lack of a
single owner thread for pipeline state:

1. **`choose_codec()` calling `gst_video_overlay_expose()` right after an
   async `PLAYING` transition it only waited ≤100ms for** — fixed
   2026-09-13 (uncommitted at time of writing), was unconditional in
   `dd95564`. `gst_element_get_state(renderer_used->pipeline, ..., 100 *
   GST_MSECOND)` (currently `video_renderer.c:1511`) can return before
   `gst_kms_sink_start()` (running on GStreamer's own state-change thread)
   has actually finished setting up `self->fd`/`self->plane_id`. Calling
   into kmssink's `GstVideoOverlay` interface from the RAOP mirror thread
   at that exact moment is undefined-behavior territory. `-replay`'s
   single-threaded feeding never hit this window; real AirPlay client
   timing did, every time (first-frame-frozen incident). Current code
   (`video_renderer.c:1535`) avoids the expose() call at this specific
   site (`force_redraw=false`) but the underlying "RAOP mirror thread
   calls straight into kmssink right after an async state change it didn't
   actually wait out" shape is unchanged — this specific symptom is gone,
   the structural risk is not.

2. **`raop_rtp_start_audio()`'s redundant-SETUP path re-creating the audio
   thread from scratch** (`raop_rtp.c:664-680`) whenever the previous
   audio thread has already exited — normal for a real reconnect, but
   nothing here inspects *why* the thread died before deciding to silently
   restart it with a brand new port. Combined with repeated real
   TEARDOWN/SETUP cycles (from the bug below), this produced the "audio
   SETUP loops forever with a fresh port every ~1-2s" incident tonight.

3. **`video_renderer_hide_video()` doing a real, synchronous
   `drmModeSetPlane` + vsync-wait directly inside the httpd thread's
   TEARDOWN response handler** (root-caused in
   `bugs/2026-09-13-audio-resume-latency-after-teardown.md`) — turned a
   previously free `skip_video_rebuild = true;` flag-set into a blocking
   DRM call sitting directly on the client-visible RTSP round-trip,
   because nothing in this codebase distinguishes "cheap, thread-safe to
   do inline" work from "must run on the pipeline's owning thread, defer
   it" work. There is no such distinction anywhere in the code today —
   every call site just calls straight into GStreamer/kmssink from
   whatever thread happens to be running.

All three share the same shape: a thread that isn't "the" pipeline-owning
thread reaches directly into pipeline/element state, at a moment nothing
in the code guarantees is safe, because nothing designates who owns that
state or requires callers to hand off to them.

## 7. What's NOT covered by this document

- `raop_rtp.c`'s own internal locking (`run_mutex`) around `running`/
  `joined`/volume/flush/metadata fields — real and correctly used *within*
  that file (confirmed while writing section 5), just not exhaustively
  re-derived here; only the *cross-file* gap (nothing in `audio_renderer.c`
  or the httpd-thread call path takes any lock at all) is in scope.
- ALSA's own internal buffering/thread-safety once `alsasink` hands data
  off to it — treated as an opaque, correctly-synchronized dependency,
  same as GStreamer-internal threading below.
- HLS/coverart-playback pipeline paths (`playbin`/`playbin3`) — mentioned
  only where they intersect the mirror-mode code paths above.
- Exact GStreamer-internal threading (how many threads `v4l2h264dec`/
  `kmssink` themselves spin up, and their own locking) — treated as an
  opaque, correctly-synchronized-internally dependency; only the
  *boundary* (what uxplay.cpp/video_renderer.c call into them, from which
  thread) is in scope here.

## Where this leaves us

Per the user: the next step is a deliberate fork, not something this
document decides —
1. Invest in the test framework so it can actually reproduce
   multi-threaded timing bugs like the ones in section 6 (today,
   `-replay` structurally cannot, per section 1), **or**
2. (stated preference) reduce the actual number of independent threads
   that touch pipeline/renderer state, so most of section 6's bug class
   stops being possible by construction rather than needing to be caught
   by a better test.

This document is meant to be the shared factual basis for making that
choice, not an argument for either side.
