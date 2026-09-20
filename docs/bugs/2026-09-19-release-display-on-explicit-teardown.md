# Feature: release the DRM display plane on explicit mirror teardown

Status: design doc written before implementation (bug-fix protocol step 3);
section 7 filled in after implementation (step 5).

## 1. Description / goal

Today, `video_reset()`'s `RESET_TYPE_RTP_SHUTDOWN` case (`uxplay.cpp:2514-2528`)
only sets `skip_video_rebuild = true;` on a plain "stop mirroring" TEARDOWN —
the pipeline, and kmssink's last-rendered frame held on DRM overlay plane 98,
are left exactly as-is. This is deliberate and stays unchanged here: it's why
a fast reconnect costs ~100ms instead of a full ~5s pipeline rebuild
(`uxplay.cpp:125-127`).

Separately (already implemented, out of scope for this doc): a read-only idle
menu screen now lives on DRM primary plane 86, and shows through automatically
whenever plane 98 has no buffer composited on it (`docs/framebuffers-and-drm-
planes.md`). Goal here: make plane 98 empty on explicit teardown too, so that
menu becomes visible immediately, without touching the appsrc/decoder state
the fast-reconnect path depends on.

## 2. Why this is high-risk here specifically

This exact class of change ("hide video on disconnect") was attempted and
reverted three times in one night (2026-09-13, submodule `dd95564` reverted
by `d2731a6`). All three failures shared one shape: a thread that isn't the
pipeline-owning thread reached directly into kmssink/pipeline internals at a
moment nothing in the code guarantees is safe (`docs/video-pipeline.md`,
"Known race windows"):

1. `gst_video_overlay_expose()` called from the RAOP mirror thread right
   after only waiting <=100ms for an async PLAYING transition -> first frame
   of the next connection came up frozen.
2. A stuck redundant-SETUP loop killed audio (root cause not fully pinned
   down before the revert).
3. `video_renderer_hide_video()`'s forced redraw did a real, synchronous
   `drmModeSetPlane` + vsync wait directly inside the httpd thread's
   TEARDOWN-response path (`docs/bugs/2026-09-13-audio-resume-latency-after-
   teardown.md`) -- turned a previously free flag-set into a blocking DRM
   call sitting on the client-visible RTSP round-trip, pushing audio-resume
   latency from ~1-2s to >3s.

## 3. Last known good

Confirmed by reading the current `uxplay.cpp` and `renderers/video_renderer.c`
before writing any code: no `GST_STATE_READY` / `render-rectangle` /
display-release logic of any kind exists on `dhabensky-clean-2` today (the
2026-09-13 revert removed all of it). There is nothing to regress from --
this is new code, not a fix to an existing broken mechanism. The current
`RESET_TYPE_RTP_SHUTDOWN` behavior (`skip_video_rebuild = true;` alone) is
itself the baseline this change must not regress.

## 4. Design

New `video_renderer_release_display()` (`renderers/video_renderer.c`),
called once from `video_reset()`'s `RESET_TYPE_RTP_SHUTDOWN` case, alongside
the existing `skip_video_rebuild = true;`. Two choices made specifically to
avoid repeating the 2026-09-13 failure shape:

**a) State transition, not a forced redraw.** Unlike the reverted feature
(`render-rectangle` + `gst_video_overlay_expose()`, which forces a real
synchronous `drmModeSetPlane` + vsync wait against the *current* buffer),
this calls `gst_element_set_state(sink, GST_STATE_READY)` on just the active
renderer's named kmssink element, found via the same `<videosink>_<codec>`
element-naming convention `video_renderer_set_overscan()` already uses
(`gst_bin_get_by_name`). READY tears down the sink's DRM plane ownership via
kmssink's own internal `stop()` path; this call site itself doesn't draw a
frame or wait for vsync. The actual cost of that internal teardown is
unmeasured until section 6/the verification report -- not assumed cheap.

**b) Deferred to the main GMainLoop, not run inline on the httpd thread.**
`video_reset()` runs synchronously on the httpd thread, inside the TEARDOWN
response handler -- exactly the call site failure #3 above blocked directly
on. `video_renderer_release_display()` itself only reads one atomic counter
and calls `g_idle_add()`; the real `gst_element_set_state()` call runs later,
from the main thread's `main_loop()` GMainLoop (or `-replay`'s
`replay_loop` -- both attach to GLib's default main context, so this is
exercisable under `-replay` too). This mirrors the pattern already
established in this codebase for the same class of problem:
`renderers/audio_renderer.c`'s `audio_renderer_start_deferred()` /
`audio_renderer_deferred_start_cb()` (2026-09-13, "Fix B" for the
httpd-thread/RAOP-audio-thread `renderer` race).

**c) Stale-release guard.** A plain `g_idle_add()` alone reopens a new race:
if the client reconnects fast enough that `video_renderer_choose_codec()`
(RAOP mirror thread) brings the pipeline back to PLAYING *before* the
deferred idle callback runs, that callback would then incorrectly re-hide a
display the reconnect just legitimately restored. New module-static atomic
`video_connect_epoch`, incremented every time `choose_codec()` (re)confirms
PLAYING; `video_renderer_release_display()` captures the current value at
schedule time, and the deferred callback compares it against the live value
before acting -- if a reconnect happened in between, it no-ops instead of
hiding the just-restored picture.

Residual, explicitly not fully closed: a genuine check-then-act race in the
narrow window between the epoch check and the `gst_element_set_state()` call
itself is still theoretically possible if a reconnect's `choose_codec()`
lands in that exact window. Not considered practically reachable given real
RTSP round-trip timing (single-digit ms at least) vs. a GMainLoop idle
dispatch (sub-ms under normal load), but stated as a known limit rather than
asserted safe -- same spirit as this project's other documented "reduced,
not eliminated" race windows.

## 5. Reconnect latency: the open question

`skip_video_rebuild` exists because a full pipeline destroy+rebuild costs
~5s vs. ~100ms for a warm reconnect. `choose_codec()` already unconditionally
calls `gst_element_set_state(renderer_used->pipeline, GST_STATE_PLAYING)` on
every invocation (`video_renderer.c:1297`) -- since a `GstBin`/`GstPipeline`
state change recurses into every child element unless that child's state is
explicitly locked (not done anywhere in this codebase), this should already
bring a `READY` kmssink back to PLAYING for free, with no new reconnect-side
code. This is a reasoned expectation from reading the code, not a
measurement -- must be confirmed on real hardware, and the actual added
latency (if any) measured, before this can be called safe to ship. See the
verification report for real numbers.

## 6. Verification plan

1. `-replay` with `UX_RECONNECT_AT_MS` as a first-pass sanity check --
   `video_reset(RESET_TYPE_RTP_SHUTDOWN)` is real production code reachable
   from the replay feeder thread, so this exercises the deferred-call
   mechanism and the epoch guard (the replay reconnect path calls
   `choose_codec()` essentially immediately after `video_reset()`, which is
   actually a good adversarial stress test of the epoch guard specifically).
   Known limitation restated: single-threaded feeder, doesn't reproduce real
   httpd-thread/RAOP-mirror-thread interleaving timing.
2. New unit test for the epoch guard logic, written against current
   (unfixed) code first and confirmed to fail, then confirmed to pass with
   the fix -- per the mandatory 6-step protocol.
3. `tools/synthetic-client.cpp`'s `threadtest` mode: read before use: it
   drives SETUP/audio/TEARDOWN cycles only (`mode_threadtest()`,
   `tools/synthetic-client.cpp:253`, `docs/testing.md`'s own table) -- no
   mirror-mode video RTP session, no video codec negotiation. It does not
   cover this change and won't be used to claim coverage it can't provide.
4. Real-hardware checks: `tools/pytest/test_video_reconnect.py` and
   `test_render_health.py` (both need `pi_hardware`) before/after for a
   clean baseline, plus `tools/drmdump.c` polling plane 98/86 across a real
   teardown to confirm plane 98 actually empties and plane 86 (the menu)
   becomes visible.
5. Real reconnect-latency measurement on the Pi, methodology TBD at write
   time, real numbers reported either way.
6. Real AirPlay client (Mac/iPhone) doing the actual "stop mirroring"
   gesture -- explicitly flagged if unavailable in this environment, with
   the concrete fallback used instead.

## 7. What was actually done / verification results

Implemented as designed in section 4 -- no deviation. See the developer's
final report for full command output; summary:

- `renderers/video_renderer.c`: added module-static atomic
  `video_connect_epoch`; `video_renderer_choose_codec()` increments it right
  after confirming PLAYING; new `video_renderer_release_display_cb()`
  (idle-dispatched) + `video_renderer_release_display()` (public, callable
  from any thread).
- `renderers/video_renderer.h`: new prototype.
- `uxplay.cpp`: one new call, `RESET_TYPE_RTP_SHUTDOWN` case, alongside
  `skip_video_rebuild = true;`; plus test-only additions to
  `replay_do_reconnect()` (`UX_RECONNECT_PAUSE_MS` env-gated sleep, a
  `choose_codec()` timing marker) needed to actually exercise/measure this
  change under `-replay`, since `-replay`'s own simulated reconnect is
  otherwise back-to-back with the teardown and never gives the deferred
  release a real gap to run in.
- `tests/test_release_display_epoch_guard.c`: new unit test, wired into
  `tools/run-unit-tests.sh`. Confirmed failing against a temporarily
  neutered (no-epoch-check) variant of the callback, passing against the
  real fix -- see the developer's report for the exact before/after output.

**Reconnect latency (the open question): resolved, stays near the ~100ms
warm-reconnect ballpark, not the ~5s cold-rebuild one.** Measured on real Pi
hardware via `-replay` + `UX_RECONNECT_PAUSE_MS` (2000ms and 5000ms) +
`GST_DEBUG=kmssink:6`: gap between the last pre-teardown render and the
first post-reconnect render, minus the artificial pause, was ~91ms (2s
pause run) and ~92ms (5s pause run) -- consistent across two different
READY-dwell times, so not a coincidence of one run's timing. Baseline
(pre-fix binary, kmssink never leaves PLAYING) showed no gap at all beyond
the normal ~100ms inter-frame cadence.

**Plane-level confirmation**: `tools/drmdump.c` polled during a real
`-replay` release window showed plane 98 going from actively composited
(`crtc_id=97 fb_id=672`) to fully released (`crtc_id=0 fb_id=0`) for the
whole duration of an 8s simulated gap, then recovering after reconnect --
direct, positive confirmation of the mechanism this change relies on.

**Regression suites**: `tools/pytest/test_video_reconnect.py` and
`test_render_health.py` (all 11 cases, real Pi hardware) pass against this
working tree.

**Coverage gap, stated plainly**: no real AirPlay client (Mac/iPhone) was
available in this environment, so the actual "stop mirroring" gesture was
never exercised end-to-end against real client timing -- every check above
is `-replay`-driven (single feeder thread) or plane/log inspection.
`tools/synthetic-client.cpp`'s `threadtest` mode was confirmed (by reading
`mode_threadtest()` and `docs/threadtest.md`) to be SETUP/audio/TEARDOWN
only -- no mirror-mode video RTP session exists in any of its modes -- so
it cannot cover this change and wasn't used to claim coverage it doesn't
have. The httpd-thread/RAOP-mirror-thread real interleaving that caused all
three 2026-09-13 regressions is therefore not directly reproduced here;
the epoch guard is unit-tested and reasoned about, not empirically raced
against real thread timing.

## 8. 2026-09-20: real-hardware failure, and §4-new's root-cause findings

**What happened after section 7's "done"**: this mechanism went through a
full developer/reviewer cycle (including the `-replay`+`UX_RECONNECT_PAUSE_MS`
latency measurement and the plane-98-clears `drmdump` check in section 7
above) and was deployed. Against a **real Mac client**, on the very first
disconnect (implicit, missed-heartbeat -- predates this change entirely) a
stalled frame was still visible; after the first *explicit* disconnect,
video never resumed on any later reconnect for the rest of the process's
life; a second disconnect was silently ignored (audio kept playing); the
audio-continues symptom recurred intermittently. **Reverted on the live Pi**
(binary checksum `8dd8af5585030730f7e35bc1fb7089d45c4f4be315f39535979e2441e7268598`,
confirmed matching the pre-§4 build -- this is the currently-deployed,
known-safe binary as of this writing). This section documents the follow-up
investigation (plan `§4-new`, step 0) done with real `drmdump` polling and a
new mirror-mode-capable `tools/synthetic-client.cpp` (see
`docs/threadtest.md`'s `mirrortest` mode) on the real Pi, instead of guessing.

### 8.1 Does a full pipeline teardown+rebuild actually clear plane 98? Yes, confirmed.

The plan's "New finding" worried that even the *unmodified*, pre-existing
`RESET_TYPE_NOHOLD` path (`video_renderer_stop(); video_renderer_destroy();
video_renderer_init(...); video_renderer_start();`, fired by the missed-
feedback/`-reset` timeout, `uxplay.cpp:2503-2525`) might not clear plane 98,
based on the user reporting a stalled frame on the very first disconnect.

Tested directly: `tools/synthetic-client.cpp`'s new `mirrortest` mode (see
8.3) opened a real mirror session against a real, unmodified
`uxplay_debug` (`-reset 8`) carrying a **real decodable H.264 keyframe**
(extracted from `tools/captures/resolution-change-gap-repro.cap`), then went
silent (`--no-teardown --idle-s`, sending no TEARDOWN and no `/feedback`,
reproducing "client vanished"). `drmdump` polled every 1-2s:

```
offset=1s..8s:  plane 98: crtc_id=97 fb_id=677   (actively composited)
offset=9s:      plane 98: crtc_id=0  fb_id=0     (server log: "lost connection
                                                    with client ... exceeds
                                                    limit of 8 seconds" fired
                                                    between the 8s and 9s polls)
offset=10s..15s: plane 98: crtc_id=0  fb_id=0    (stays cleared)
```

Plane 98's content during the active window was pixel-verified, not assumed:
`ffmpeg -f rawvideo -pixel_format gray -video_size 1664x1080 -i
<dump>.plane98.p0.raw -vf crop=1662:1080:0:0 out.png` on the dumped Y-plane
showed the real captured frame (the macOS Screen Mirroring picker over a
YouTube video) -- i.e. this was genuine, hardware-decoded video, not a
placeholder, and it cleared cleanly on the unmodified full-rebuild path.

**Conclusion: the pre-existing `video_renderer_destroy()`+`init()`+`start()`
path does clear plane 98, at least in this real, controlled repro.** The
"first disconnect still left a stalled frame" symptom from the real-Mac
report was not reproduced here and is not explained by this doc's original
"why this is safe" argument being wrong -- it may be a different mechanism
(e.g. what the user perceived as a stalled frame could plausibly be the
still-under-construction §5 idle-menu-bleeds-into-pillarbox bug, or a
timing-specific race not triggered by this synthetic repro's exact
sequencing); **not resolved by this investigation, flagged as open**.

### 8.2 The leading hypothesis (release_display's mechanism is wrong) -- confirmed, with two distinct problems

Reinstated `video_renderer_release_display()` (this doc's section 4) in a
**throwaway local build only** (never deployed to `/usr/local/bin`, built
to `/tmp/uxplay_debug_relDisp`; reverted via `git checkout --
renderers/video_renderer.c renderers/video_renderer.h uxplay.cpp` before
finishing -- not part of this round's diff), with added `logger_log`
state-dump lines around both `video_renderer_release_display_cb()`'s
`gst_element_set_state(sink, GST_STATE_READY)` and `choose_codec()`'s
`gst_element_set_state(pipeline, GST_STATE_PLAYING)`, each logging both the
**pipeline's** and the **kmssink child's** own `gst_element_get_state()`
result.

**Finding 1 -- the mechanism doesn't even release the plane.** A real
mirror session (one `mirrortest` cycle, real decoded frame, real explicit
TEARDOWN) was run against this build. `release_display: set kmssink_h264 to
READY` printed (the deferred callback did run), but `drmdump` polled every
0.05-3s afterward showed plane 98 **unchanged** the entire time:

```
before TEARDOWN:      plane 98: crtc_id=97 fb_id=673
+0.05s .. +3s (after "set to READY"):
                       plane 98: crtc_id=97 fb_id=677   (unchanged throughout)
```

`gst_element_set_state(kmssink_element, GST_STATE_READY)` on just the child
element does **not** trigger the plane-disable DRM commit this doc's
section 4 design assumed kmssink's internal `stop()` path would perform --
contradicting "READY tears down the sink's DRM plane ownership via
kmssink's own internal `stop()` path" (section 4a above). This is a real
measurement, not source reading: `gst-plugins-bad`'s `sys/kms/gstkmssink.c`
source was not available via `apt-get source` in the buildenv container
(not attempted further given the empirical result already answers the
question directly).

**Finding 2 -- pipeline/child state desync, confirmed.** The added state
logging, across a 2-cycle `mirrortest` run (explicit TEARDOWN then an
immediate reconnect SETUP, `--gap-s 0`):

```
DBGSTATE choose_codec pre:  pipeline=PAUSED  sink(kmssink_h264)=READY
DBGSTATE choose_codec post: pipeline old=PAUSED  new=PLAYING  sink=READY
release_display: set kmssink_h264 to READY
DBGSTATE release_display post: pipeline=PAUSED  sink=READY
DBGSTATE choose_codec pre:  pipeline=PLAYING sink(kmssink_h264)=PLAYING
DBGSTATE choose_codec post: pipeline old=PLAYING new=VOID_PENDING sink=PLAYING
release_display: set kmssink_h264 to READY
DBGSTATE release_display post: pipeline=PLAYING sink=READY
DBGSTATE choose_codec pre:  pipeline=PLAYING sink(kmssink_h264)=READY
DBGSTATE choose_codec post: pipeline old=PLAYING new=PLAYING sink=READY
```

Right after `release_display_cb` sets the child to READY, the pipeline's
own `gst_element_get_state()` reports **PAUSED** (not READY, not PLAYING) --
a real, observed mismatch between the child's actual state and the parent
`GstPipeline`'s own cached/aggregate state, confirming the doc's leading
hypothesis that setting a child element's state directly, bypassing the
parent, desyncs the two. The very next `choose_codec()` call (the
reconnect) then reports `pipeline=PLAYING sink=PLAYING` *before* it has done
anything itself -- i.e. something (GStreamer's own bin/child target-state
reconciliation, not any explicit call in this codebase) silently re-promoted
the child back toward the bin's last-commanded target state at some point
between the two log lines, independent of and prior to `choose_codec()`'s
own `gst_element_set_state(pipeline, PLAYING)` call. Combined with Finding
1 (the plane was never actually released at the KMS level in the first
place), this is consistent with, but does not by itself prove, the
regression's reconnect-side symptoms.

**Finding 3 -- matches the real regression's shape.** In that same 2-cycle
run, `drmdump` polled every ~0.4s across both cycles (cycle 0 teardown,
immediate cycle 1 reconnect+5 frames+teardown) showed plane 98's `fb_id`
change once early (673 -> 674) and then **stay at 674 for the rest of the
run**, through all of cycle 1's own 5 fresh frames. Cycle 1's video did not
visibly resume/refresh on the plane -- the same shape as the real regression
report ("video never resumed on any subsequent reconnect"), reproduced here
without a Mac.

### 8.3 `tools/synthetic-client.cpp`: added real mirror-mode + TEARDOWN coverage, fixed two real pre-existing bugs found along the way

New `mirrortest [N] [--gap-s S] [--no-teardown] [--idle-s S]` mode (see
`docs/threadtest.md` for full usage) -- real type=110 SETUP, a real TCP
mirror-data connection, real AES-CTR-encrypted H.264 frames (SPS/PPS +
keyframe extracted from `tools/captures/resolution-change-gap-repro.cap`),
and a real TEARDOWN, repeated over N cycles on one control connection.
Verified genuinely working end-to-end on real Pi hardware, not just
protocol-level: `h264parse` reports zero "broken nal" warnings, `kmssink`
negotiates real DMABuf frames, and the rendered pixels were confirmed (via
`drmdump` + `ffmpeg`) to be the real source frame, hardware-decoded.

Building this surfaced two real, previously-latent bugs, both fixed (both
are in `tools/synthetic-client.cpp` only, not in the library):

1. **`handshake()`'s FairPlay mode byte was never set.** `fp2[12]` (read as
   `mode` by `lib/playfair/omg_hax.c`'s `decryptMessage()`, indexing
   `message_key[4][]`/`message_iv[4][]`) was left as random bytes from
   `get_random_bytes(fp2, ...)`. Any value outside `{0,1,2,3}` is an
   out-of-bounds table read -- undefined behavior that happened to return a
   different, non-deterministic `aeskey` on the client vs. the server (two
   separate binaries/processes/memory layouts), confirmed by instrumenting
   `fairplay_decrypt()` directly (same `keymsg`/`input` bytes on both sides,
   different `output`). Fixed by setting `fp2[12] = 0x00`, matching `fp1`'s
   own mode (`fp1[14] = 0x00`). This is a pre-existing bug in code shared by
   every mode (`threadtest`, `ntpresync`, `resendstorm`, `resendrecovery`)
   -- plausibly the real explanation for `docs/threadtest.md`'s long-standing
   "Known limitation" (repeated AAC-ELD content always failing its
   marker-byte validity check), though re-diagnosing that specific claim
   was not attempted here (out of scope for this round; flagged for whoever
   next touches `threadtest`).
2. **SPS/PPS-to-keyframe timestamp mismatch, mine.** `raop_rtp_mirror_thread()`
   only prepends a pending SPS/PPS to the *next* video packet if its
   `ntp_timestamp_raw` exactly matches the SPS/PPS packet's own (silently
   discarding it otherwise, no error) -- `mode_mirrortest()` was advancing
   the timestamp before sending the first frame, so this never matched and
   every frame arrived at the decoder with no in-band SPS/PPS, which
   `h264parse` correctly called broken. Fixed by keeping the first frame's
   timestamp identical to the SPS/PPS packet's, matching a real client.

### 8.4 State on the live Pi at the end of this round

Confirmed via `sha256sum /usr/local/bin/uxplay_debug` on the live Pi:
`8dd8af5585030730f7e35bc1fb7089d45c4f4be315f39535979e2441e7268598` -- the
known-safe, pre-§4 binary, `uxplay.service` running normally. All diagnostic
builds/binaries used in this section were run from separate paths (`/tmp/`)
or as standalone processes, never deployed to `/usr/local/bin`, and were
killed/removed before finishing.

### 8.5 What this means for §4-new's step 1 (next round, not this one)

Section 8.2's plan-quoted candidates should be re-weighed with this
evidence:
- Direct child-element `GST_STATE_READY` (the original mechanism) is now
  empirically ruled out, on two independent grounds (doesn't release the
  plane at all; desyncs pipeline/child state) -- not just "risky by
  analogy" to the 2026-09-13 failures anymore.
- The plan's black-frame-via-`gst_app_src_push_buffer()` alternative was not
  tested this round (out of scope: this round was investigation + test
  infra only) but is not contradicted by anything found here, and doesn't
  touch element state at all -- worth trying first next round.
- Whether a raw `drmModeSetPlane`(fb_id=0) via kmssink's own already-open fd
  is reachable, and whether it's actually necessary given the black-frame
  alternative might suffice, is still open and untested.

`tools/synthetic-client.cpp`'s `mirrortest` mode (8.3) is available as a
real, repeatable regression check for whatever step 1/3 tries next --
confirmed capable of reproducing this regression's shape (8.2, Finding 3)
without a Mac.

## 9. 2026-09-20: Candidate A implemented (render-rectangle hide/restore, deferred + epoch-guarded) -- strong partial verification, not deployed

Per §4-new step 1's re-weighing (8.5): tried the render-rectangle-based
approach first, reusing the deferred `g_idle_add()` + epoch-guard design
from section 4 above but replacing the broken action (bare child-element
`GST_STATE_READY`) with the render-rectangle move-off-screen +
`gst_video_overlay_expose()` approach from the reverted 2026-09-13 feature
(`dd95564` on the pre-rebuild branch history; not present on
`dhabensky-clean-2` before this round -- confirmed via `git log`/`grep`,
so this is new code here, not a revert). Candidate B (black frame via
`gst_app_src_push_buffer()`) was not attempted -- see "Why B wasn't tried"
below.

### 9.1 What was implemented

`renderers/video_renderer.c`:
- `static gint video_connect_epoch = 0;` -- bumped by `choose_codec()`
  every time it (re)confirms `PLAYING`, exactly as designed in section 4c.
- `static void apply_render_rectangle(const char *rect, gboolean
  force_redraw)` -- new shared helper, factored out of the property-set
  loop `video_renderer_set_overscan()` already had; `force_redraw` also
  calls `gst_video_overlay_expose()` (only used by the hide path).
- `video_renderer_set_overscan()` now caches the exact rect string it last
  applied (`cached_overscan_rect`) and the screen dimensions
  (`cached_screen_w/h`), so the restore path (below) doesn't need
  overscan config threaded back in from `uxplay.cpp`.
- `static gboolean video_renderer_release_display_cb(gpointer data)` --
  the deferred callback: epoch-checks first (no-ops and logs if a
  reconnect raced ahead), else builds `<-screen_w,0,screen_w,screen_h>`
  (full-size, shifted off the left edge -- the exact geometry trick
  `dd95564`'s commit message worked out: a degenerate `<0,0,1,1>` rect
  makes `gst_video_sink_center_rect()`'s aspect-fit round to <=0 and
  kmssink silently skips the DRM commit; only the right/bottom edges are
  clamped, never a negative left edge) and calls
  `apply_render_rectangle(rect, TRUE)`.
- `void video_renderer_release_display(void)` -- public, callable from
  any thread: captures the current epoch, `g_idle_add()`s the callback
  above. Called once, from `uxplay.cpp`'s `video_reset()`
  `RESET_TYPE_RTP_SHUTDOWN` case, alongside the existing
  `skip_video_rebuild = true;` -- unchanged from section 4's design.
- `choose_codec()`: right after confirming `PLAYING` (before the
  `renderer_used == renderer` early return, so it fires on every
  reconnect, idempotently), bumps `video_connect_epoch` and calls
  `apply_render_rectangle(cached_overscan_rect, FALSE)` -- the restore.

No `gst_element_set_state()` call exists anywhere in this new code --
the mechanism only ever does a GObject property set and (hide path only)
`gst_video_overlay_expose()`. This is the structural difference from the
reverted section-4 mechanism that (8.2) confirmed causes a real
pipeline/child state desync.

`renderers/video_renderer.h`: new `video_renderer_release_display(void)`
prototype. `uxplay.cpp`: one new call site, `video_reset()`'s
`RESET_TYPE_RTP_SHUTDOWN` case.

### 9.2 Regression test

`tests/test_release_display_epoch_guard.c` (new -- the file this doc's
plan referenced as "exists from the reverted attempt" does not actually
exist on this branch; the whole reverted attempt in 8.2 was built in
`/tmp` and `git checkout`-reverted, never committed). Links
`video_renderer.c` directly (same pattern as
`test_bus_callback_null_renderer.c`) and exercises the real
`video_connect_epoch` guard and the real `video_renderer_release_display_cb()`/
`video_renderer_release_display()`, including one case that drives the
real public entry point through a real default-`GMainContext` `g_idle_add()`
dispatch (`g_main_context_iteration(NULL, FALSE)`), not just the callback
in isolation. Four cases: unchanged-epoch hide fires; reconnect-raced
epoch suppresses the hide; same two cases again through the public
`video_renderer_release_display()` entry point. Wired into
`tools/run-unit-tests.sh`.

Per the mandatory protocol: manually neutered the guard (`if (0 && ...)`
instead of the real epoch comparison, in a throwaway local edit, reverted
before finishing) and confirmed the test suite fails (an `assert`
aborts) with the guard disabled, then confirmed it passes again with the
real guard restored -- output captured directly, not assumed.

### 9.3 Real-hardware verification: what was confirmed, and a real gap

All runs below used `tools/synthetic-client.cpp`'s `mirrortest` mode
against the candidate binary run as a **standalone process on the real
Pi** (`/tmp/uxplay_debug_candA`, never copied to `/usr/local/bin`,
`uxplay.service` stopped for the duration of each run and always
restarted with the known-safe binary immediately after -- verified via
`sha256sum` after every single run in this section, no exceptions).

**Confirmed, positive: the hide fires correctly and for real.** A 10-cycle
`mirrortest --gap-s 2` run, `drmdump` polled every 0.1-0.2s throughout:
after each of the 10 real explicit TEARDOWNs, plane 98's on-screen dest
rect (`CRTC_X`) moves from its normal position to `CRTC_X=-1791`
(`CRTC_W=1662`, i.e. the full negative-screen-width shift, exactly the
designed geometry) and **stays there** for the whole inter-cycle gap.
Confirmed across two independent 10-cycle runs.

**Confirmed, positive: the restore call's logic and value are both
correct.** The server log shows, for every single one of the 10 cycles,
`raop_rtp_mirror starting mirroring` immediately followed by `video
renderer: set kmssink_h264 render-rectangle to <0,0,1920,1080>` (the
correct, full-screen restore value) -- i.e. `choose_codec()`'s restore
call fires on every real reconnect, with the right value, before the next
TEARDOWN's hide. A **separate, no-teardown control run**
(`mirrortest 1 --no-teardown --idle-s 6` -- one connection, 5 frames,
then 6s idle with no TEARDOWN ever sent, so `release_display()` never
fires at all) confirms the underlying mechanism this restore call uses
(`apply_render_rectangle()`, a plain property set) genuinely produces a
**visible, correctly-positioned** picture when nothing has hidden it:
`CRTC_X=129` the entire 6s window (the correct aspect-fit-centered
position for a 1662-wide decoded picture on a 1920-wide screen -- matches
`(1920-1662)/2`), never `-1791`. This is the same code path
(`apply_render_rectangle`) the restore call uses, just invoked from
`video_renderer_set_overscan()` at startup instead of from `choose_codec()`
on reconnect -- so the mechanism itself is confirmed correct in isolation.

**Not confirmed via `drmdump`: whether the restore visually takes effect
on a real reconnect's own frames.** Every 10-cycle run (two independent
`--gap-s 2` runs, plus a `--gap-s 0` fast-reconnect run) showed plane 98's
`CRTC_X` at `-1791` for **every** sample taken during or after cycle 0,
including inside what should have been each reconnect's brief visible
window -- never observed flipping back to the restored position. Chased
this down rather than accepting it as "candidate A is broken", because it
contradicted 9.2's positive control result. Root cause, confirmed by
direct measurement, not guessed:

1. **A real, previously-undocumented `mirrortest` limitation: plane 98
   stops receiving new DRM commits after only ~2 real buffers per
   connection, independent of reconnects entirely.** The same
   no-teardown control run above (9.3, no reconnect, no hide, nothing to
   confound the reading) shows `fb_id` reach `672` then `677` and then
   **freeze at `677` for the remaining ~25 of 27 samples across the full
   6s idle window**, despite 5 real frames having been sent and
   individually confirmed reaching `v4l2h264dec` (`GST_DEBUG=
   kmssink:6,v4l2videodec:5,h264parse:5`: "Handling frame 0" through
   "Handling frame 4" all logged, h264parse reports zero broken-nal
   warnings). **Confirmed identical on a completely unmodified baseline
   binary** (this round's working tree `git stash`-ed back to HEAD,
   rebuilt, same 6-cycle `mirrortest` run): `fb_id` sequence `671 -> ...
   -> 677`, froze the same way, same shape. This is not a Candidate A
   regression -- it reproduces on code with zero changes from this round.
   Likely cause (plausible, not proven further -- out of scope to fully
   root-cause this round): `mirrortest` sends the *same* captured H.264
   IDR slice (identical `frame_num`/POC fields, identical bytes) for
   every one of a cycle's 5 frames and for every cycle, which a real
   hardware decoder may not be designed to receive repeatedly without
   the normal frame-to-frame variation a real encoder produces --
   matching this project's own established pattern of synthetic replayed
   content hitting real decoder edge cases (`docs/threadtest.md`'s
   AAC-ELD "Known limitation" is the audio-side precedent for exactly
   this shape of problem).
2. **Cold pipeline/decoder startup latency can also outrace the RTSP
   protocol timeline on a fresh connection.** A `--gap-s 0` 2-cycle run
   showed plane 98 stay fully inactive (`crtc_id=0`) for ~1.4 real
   seconds after the *whole 2-cycle mirrortest exchange had already
   completed* (both SETUPs, both TEARDOWNs, done in ~540ms) -- kmssink's
   `gst_kms_sink_start()` and the v4l2 decoder's own format negotiation
   take real wall-clock time on a cold pipeline (separately confirmed via
   `GST_DEBUG`: kmssink's own startup sequence alone spans several hundred
   ms), so by the time the first-ever real commit lands, later cycles'
   TEARDOWNs (and hides) may have already fired.

Both (1) and (2) are `mirrortest`/pipeline-cold-start timing artifacts,
not something in this round's diff -- (1) especially, since it's
reproduced letter-for-letter on unmodified code. Given (1) alone caps
real per-connection commits at ~2 regardless of reconnects, a clean
"restore visibly takes effect on cycle N+1" `drmdump` capture is not
achievable with `mirrortest` as it exists today; doing so would need
`mirrortest` extended to send genuinely varying frame content (multiple
distinct real captured frames per cycle, not one frame repeated), which
is real, separate infrastructure work, not attempted this round.

**Re-reading 8.2's Finding 3 in light of this**: 8.2's 2-cycle run (the
*broken*, since-reverted mechanism) observed `fb_id` change once then
freeze through cycle 1's frames, read at the time as matching the real
regression's shape. Given finding (1) above, that freeze pattern alone
cannot be taken as specific confirmation of the state-desync hypothesis
-- the freeze may well have happened regardless of which mechanism (or
no mechanism at all) was active. This doesn't overturn 8.2's Finding 2
(the direct `GST_STATE()` logging showing pipeline/child desync is
independent, real evidence, unaffected by this), but the Finding 3
corroboration is weaker than it read at the time. Noted here rather than
silently left uncorrected; re-litigating it fully is out of scope.

**Reconnect/TEARDOWN latency: flat, matches baseline, no regression.**
Across the 10-cycle `--gap-s 2` run: `TEARDOWN`-response latency
(`SEND-TEARDOWN` to `RECV-TEARDOWN-response`) was 45.7-51.5ms per cycle,
mean 47.4ms, no growth trend across the 10 cycles. The same measurement
against the unmodified baseline binary (6-cycle run): 46.1-51.2ms, mean
47.0ms -- statistically indistinguishable. `video_renderer_release_display()`
itself only does an atomic read and a `g_idle_add()` call inline on the
httpd thread (no GStreamer call at all until the deferred callback runs
later, on the main thread) -- this measurement confirms that stays true
in practice, not just in the code. No sign of the 2026-09-13
httpd-thread-blocking regression class recurring.

### 9.4 Why Candidate B wasn't tried this round

Candidate B (`gst_app_src_push_buffer()` black frame) depends on exactly
the same thing 9.3 found `mirrortest` can't currently deliver: a fresh,
observable commit reaching plane 98/86 after a reconnect. Switching to it
would not sidestep 9.3's actual gap, and per the task's own framing, B is
a fallback for when A is shown *unsafe*, not for when a specific piece of
A's verification is inconclusive for tooling reasons -- A was not shown
unsafe here. Given the effort already spent chasing 9.3's `drmdump` gap
down to a real, external root cause, B was not attempted this round.

### 9.5 State on the live Pi at the end of this round

`uxplay.service` running the known-safe binary throughout and at the end
of this round, confirmed via `sha256sum /usr/local/bin/uxplay_debug`
after every single diagnostic run in 9.3 (not just once at the end):
`8dd8af5585030730f7e35bc1fb7089d45c4f4be315f39535979e2441e7268598`.
**Candidate A's code is in the working tree (`renderers/video_renderer.c`,
`renderers/video_renderer.h`, `uxplay.cpp`) but was never deployed to
`/usr/local/bin` or run via `uxplay.service`** -- every test in 9.3 ran a
separately-built binary as a standalone process, killed before
`uxplay.service` was restarted each time.

### 9.6 Recommendation

Not deploying this round. The evidence gathered is genuinely strong on
several fronts (hide fires and holds; restore's logic, timing, and value
are all independently confirmed correct; latency is flat and matches
baseline; the mechanism structurally cannot reproduce 8.2's confirmed
pipeline/child desync root cause, since it never touches element state).
But the one thing that failed catastrophically last time -- "does video
visibly come back after a reconnect" -- is exactly the piece 9.3 could
not pixel-confirm, for reasons now root-caused to `mirrortest`, not to
this candidate. Given this is the second real-hardware failure of this
bug class and the user's own standing instruction not to deploy without
genuine confidence, that one unresolved gap is enough to withhold
deployment rather than lean on the (real, but partial) evidence above.
Next steps, not done this round: either extend `mirrortest` to send
varying frame content per cycle (closing 9.3's gap properly) and re-run,
or test against a real AirPlay client if one becomes available in this
environment (confirmed unavailable this round -- no physical Mac/iPhone
or client software reachable from this sandboxed session).

## 10. 2026-09-20: mirrortest fixed to send real varying frames -- Candidate A pixel-confirmed across 10 reconnects, deployed

Closes 9.3's gap and 9.6's decision point: `mirrortest` now sends a real,
temporally-varying frame sequence, the tool was proven trustworthy on the
unmodified baseline binary first, and Candidate A was then re-verified
with real pixel/fb_id evidence across 10 real reconnect cycles.

### 10.1 `mirrortest` fix: real frames loaded from a .cap fixture, not one repeated NAL

`tools/synthetic-client.cpp`: removed the ~4000-line hardcoded single-IDR
byte array (`kRealH264Sps`/`Pps`/`VclNal`) and replaced it with a small
runtime loader, `load_mirror_frames()` + `split_annexb_nals()`, that reads
a `-capture`-format `.cap` file's `'V'` records directly (same
`[type][mono_ns][ntp][len][data]` layout `uxplay.cpp`'s `cap_write()`/
`tools/trim-capture.py` already use) and splits each record's Annex-B NALs
by start code. Record 0 of any real capture is a genuine SPS+PPS+IDR
bundle (confirmed by direct inspection, both here and previously); later
records are single real VCL NALs. `send_mirror_sps_pps()`/
`send_mirror_video_frame()` now take these dynamically instead of fixed
globals. New flags: `--frames-cap PATH` (default
`tools/captures/trimmed/personalmac-stall-20260911-10s.cap`, an
already-committed 10s/267-frame regression fixture -- no new binary
checked in) and `--frames-per-cycle N` (default 90, ~3s at the existing
~30fps pacing; wraps on the real IDR at index 0 if exceeded, a legal
decode restart). Net diff on this file: +376/-21 lines -- smaller than
before despite adding real functionality, since the giant embedded array
is gone.

### 10.2 Part 1: proved the tool trustworthy on the unmodified baseline first

Per the task's own requirement, tested the new frame feed against
`uxplay_debug_baseline` (checksum `8dd8af55...`, confirmed matching the
known-safe binary) before touching Candidate A. Single mirror connection,
`--no-teardown --frames-per-cycle 150` (~5s of real content), `drmdump`
polling plane 98 every ~0.35s (actual achieved interval; `sleep 0.1` plus
per-poll process-spawn overhead) throughout the send window and a 5s idle
tail:

```
fb_id sequence over ~5s of real sending:
0(x8, cold start) -> 673 -> 675 -> 673 -> 674(x2) -> 675 -> 676(x2) -> 677
 -> 673(x2) -> 674 -> 675 -> 676(x2) -> 677(x17, idle tail -- correctly
 static once no new frames are being sent)
```

12 distinct fb_id transitions across the real ~5s send window, vs. the
previously-confirmed baseline behavior of freezing after ~2 buffers
regardless of duration (9.3). Plane 98's on-screen position (`CRTC_X=129`)
stayed constant and correct throughout -- genuinely visible, not just
committing off-screen. A separate run took two full `drmdump` pixel
snapshots of plane 98's Y-plane 2s apart within one connection (fb_id 675
then 672): `cmp` found the raw bytes differ starting at byte 72 --
confirmed real, distinct decoded content, not merely a recycled fb_id
label over static pixels. Both runs used the real product server
invocation (`-vd v4l2h264dec -vc identity -srgb no -reset 60 -vs "kmssink
qos=false ts-offset=300000000" ...`, matching `uxplay.service`'s own
`ExecStart` exactly) as a standalone process, never touching
`/usr/local/bin` or a live-running `uxplay.service` beyond the stop/start
bracketing each run; `uxplay.service` was confirmed `active` with the
known-safe checksum after every run in this section.

### 10.3 Part 2: Candidate A re-verified, pixel/fb_id-confirmed across 10 real reconnects

`uxplay_debug` built from the current working tree (Candidate A's code,
checksum `d7c63dcced86b04537d641c28ed8ba2bcd883a10bc15282569bb918fb3e5c525`,
byte-identical before and after this round's comment-only cleanup of
`synthetic-client.cpp`, confirmed by re-checksumming after the cleanup
build) run standalone (never `/usr/local/bin`/`uxplay.service` until the
final deploy step below), driven by `mirrortest 10 --gap-s 2
--frames-per-cycle 90`, `drmdump` polling plane 98 throughout. Analysis of
all 10 real TEARDOWN->SETUP transitions (wallclock-correlated against
`mirrortest`'s own per-cycle timestamps):

- **Hide holds cleanly during every one of the 10 gaps**: `CRTC_X=-1791`
  for every sample in each gap window (checked with a margin excluding the
  real ~50ms TEARDOWN response RTT), 10/10.
- **Restore lands well inside each cycle's ~3s window, 10/10**: measured
  latency from `SEND-SETUP` to the first `CRTC_X=129` (correct, visible
  position) sample was 0.49-0.78s across all 10 reconnects.
- **New, genuinely varying real frames keep rendering after every single
  reconnect, 10/10** -- this is the piece 9.3/9.6 could not confirm.
  Each cycle's post-restore active window shows plane 98's `fb_id` cycling
  through multiple distinct real values (`672, 674, 675, 676, 677`,
  consistent across all 10 cycles -- a real v4l2 output buffer pool being
  genuinely reused with new content, not one static value held over).
- **TEARDOWN latency flat, no regression**: 45.7-52ms per cycle across all
  10 -- matches this doc's earlier ~47ms-mean measurement (section 9.3)
  for the same mechanism.
- No `h264parse`/decode errors in the server log; the only log noise is
  the pre-existing, expected synthetic-client artifacts (missing real NTP
  timing, feedback-interval warnings during the gap) already documented in
  `docs/threadtest.md`.

This directly closes the gap 9.6 flagged as blocking: video is now
pixel/fb_id-confirmed, not just log-confirmed, to keep rendering after a
real reconnect, across enough cycles (10) to have a real chance of
catching an intermittent race.

### 10.4 Deployed

Per the task's decision point, this is genuine evidence Candidate A
works. Deployed to the live Pi: `uxplay.service` stopped, the candidate
binary copied to `/usr/local/bin/uxplay_debug`, service restarted.
Confirmed: `systemctl is-active` -> `active`; a single stable
`uxplay_debug` process (no restart-loop); `/var/log/uxplay.log` clean, and
showing Candidate A's own distinct log-line prefix (`video renderer: set
kmssink_h264 render-rectangle to ...`, vs. the pre-Candidate-A binary's
`overscan: set ...`) as independent behavioral confirmation the new code
path is actually running, not just a checksum match.

**Live Pi state at the end of this round**: `uxplay.service` active,
running `/usr/local/bin/uxplay_debug` checksum
`d7c63dcced86b04537d641c28ed8ba2bcd883a10bc15282569bb918fb3e5c525`
(Candidate A) -- this is now the deployed binary, replacing the
known-safe `8dd8af55...` referenced throughout this doc. Left running for
the user's own manual test, per the task.

### 10.5 Notes

- Mid-round, the Pi was moved back to its home network by the user
  (`10.110.117.74` mobile-hotspot address -> `192.168.1.34` on
  `AKADO-AD88-5G`), rebooting it and wiping `/tmp`. Handled by re-copying
  all diagnostic binaries/fixtures and re-running the in-flight test from
  scratch against the new address; confirmed no stale state carried over
  (checksums re-verified after every step past the reboot).
- The mobile-hotspot link (before the move above) dropped several times
  mid-session; all orchestration scripts run against the Pi in this round
  were `nohup`/`setsid`-launched on the remote side specifically so a
  dropped SSH session can't leave `uxplay.service` stopped mid-test --
  confirmed necessary in practice (one earlier ad hoc command, not
  wrapped this way, did leave the service stopped after a drop; caught
  and restarted immediately on reconnect).
- `docs/threadtest.md` still does not document `mirrortest` at all, despite
  section 8.3/9 of this doc citing it as if it were documented there --
  a pre-existing gap from an earlier round, not addressed here (out of
  this round's assigned scope).
