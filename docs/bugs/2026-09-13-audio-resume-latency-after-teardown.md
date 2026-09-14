# Bug: audio takes noticeably longer to resume after a mirror TEARDOWN/reconnect

Status: **root cause understood; underlying feature reverted rather than
patched forward again (2026-09-13) pending a properly planned fix informed
by `docs/video-audio-threading-and-state-machine.md`.**

## 2026-09-13 update: reverted instead of patched

Given this was the *third* same-night regression from the same feature
(frozen-frame-hide, `dd95564`), the decision was made to stop patching
forward and instead revert the whole feature back to the last known-good
commit identified in section 2 below (`7402efa`) — submodule commit
`d2731a6` (`git revert dd95564`, confirmed via empty diff against
`7402efa`), main repo `4c6491b`. Verified stable via
`tools/test-reconnect-e2e.sh` and `tools/test-render-health-e2e.sh` (both
PASS) before handing off for the user's manual approval.

**This bug (and the frozen-last-frame-after-disconnect bug the reverted
feature was trying to fix) are both open again** — the analysis in
sections 2-4 below remains valid and should inform the next, properly
planned fix attempt; it just isn't applied right now.

## 1. Description (as reported)

Reported: 2026-09-13, directly after tonight's frozen-frame-on-disconnect fix
was deployed live.

- **New bug, confirmed by the user** — did not exist before tonight's
  session of fixes.
- Trigger: a "перемотка" (seek/scrub) in whatever's being mirrored causes a
  brief AirPlay mirror TEARDOWN + reconnect. Per the user, a brief audio
  interruption on this event is a **pre-existing, known AirPlay quirk**, not
  itself a bug ("так было всегда, особенность airplay").
- **What actually regressed**: audio's resume/recovery time after that
  interruption went from a historical baseline of ~1-2s to **>3s**.
- **Video is unaffected** — plays back normally throughout. The user cites
  this explicitly as evidence against a network-level explanation (if it
  were network congestion, video would show it too).
- User's own earlier report in the same session ("замерло после
  реконнекта") referred to this same event, described more tersely at
  first.

## 2. Last known good state

Per protocol: since this is confirmed new *today*, and only one submodule
commit touched the relevant code today, last-known-good is the commit
immediately before it:

- Current tip (has the bug): `dd95564` (*"Fix frozen last frame after
  disconnect being instant, not eventual"*), **plus an uncommitted local
  diff** (the `force_redraw` thread-safety fix from earlier tonight, itself
  unrelated to this bug — see below).
- Last known good: `7402efa` (*"Add configurable overscan compensation,
  tunable live via config file"*) — the commit immediately before
  `dd95564`, i.e. before the frozen-frame-hide feature existed at all.

Not independently re-tested by flashing/running `7402efa` live tonight —
the diff analysis below is precise and mechanically confirmed enough
(traced the exact code path the client's TEARDOWN request executes) that a
full empirical bisection wasn't necessary to reach a root cause. Flagging
this explicitly per the protocol rather than skipping the step silently.

## 3. Diff analysis / root cause

Full diff: `git diff 7402efa dd95564 -- uxplay.cpp renderers/video_renderer.c renderers/video_renderer.h`

The relevant change: `video_reset()`'s `RESET_TYPE_RTP_SHUTDOWN` case, for a
plain mirror-mode reconnect (`skip_video_rebuild` path):

```c
// before (7402efa): a complete no-op besides setting a flag
skip_video_rebuild = true;

// after (dd95564): also does real, synchronous rendering work
skip_video_rebuild = true;
video_renderer_hide_video();
```

`video_renderer_hide_video()` calls `apply_render_rectangle(rect, true)`
(true = force a redraw), which:
1. `gst_util_set_object_arg(sink, "render-rectangle", rect)` — cheap, a
   plain property set.
2. `gst_video_overlay_expose(sink)` — **not cheap**. This calls
   `gst_kms_sink_expose()` -> `gst_kms_sink_show_frame(self, NULL)`, which
   (since the pipeline has a real `last_buffer` from active mirroring) goes
   through the *full* render path: `gst_video_sink_center_rect()`, a real
   `drmModeSetPlane()` kernel ioctl, and `gst_kms_sink_sync()` — which waits
   for the display's vsync/page-flip to actually complete.

**Traced where `video_reset(RESET_TYPE_RTP_SHUTDOWN)` is actually called
from** (`lib/raop_handlers.h`, the RTSP TEARDOWN (type 110) handler):

```c
} else if (teardown_110) {
    ...
    raop->callbacks.video_reset(raop->callbacks.cls, RESET_TYPE_RTP_SHUTDOWN);
    ...
}
// falls through to building/sending the HTTP response for THIS TEARDOWN request
```

This call is **synchronous and inline**, directly inside the function
building the RTSP response for the client's TEARDOWN request. Whatever this
call blocks on directly delays how long it takes the server to send that
response back — and the client (per the user's own description of the
existing AirPlay quirk) doesn't resume audio until it gets that response
and re-negotiates.

**Root cause**: `video_renderer_hide_video()`'s forced redraw does a real
DRM ioctl + vsync wait synchronously inside the TEARDOWN response path,
which used to be a zero-cost flag-set. Video is unaffected because the
already-running decode/render pipeline (kept alive by
`skip_video_rebuild`) never stopped — only the client-visible RTSP
round-trip got slower, and audio's resumption is gated on that round-trip.

The other new call site added tonight,
`video_renderer_apply_overscan(false)` in `video_renderer_choose_codec()`
(the uncommitted thread-safety fix from earlier), is **not** implicated:
it was deliberately changed to skip `expose()` entirely (`force_redraw =
false`) for a different reason (a threading race), so it's cheap — no real
ioctl, just a property set.

## 4. Fix plan

Don't do the real DRM redraw work synchronously inside `video_reset()`'s
TEARDOWN-response path at all. Defer it to the process's existing
`GMainLoop` via `g_idle_add()` (already relied on elsewhere in this file
for the overscan `GFileMonitor` callback, so this is an established
pattern here, not a new mechanism):

- `video_renderer_hide_video()` (in `renderers/video_renderer.c`): rename
  the current synchronous body to a static helper, and have the public
  function schedule that helper via `g_idle_add()` instead of calling it
  directly. `video_reset()` then returns immediately after setting
  `skip_video_rebuild = true`, same as before `dd95564`.
- The visible hide still happens almost immediately in practice (next
  main-loop iteration, milliseconds under normal load) -- the fix removes
  the *blocking*, not the *speed* of the fix from last night.
- No change needed to `video_renderer_apply_overscan()`'s call sites --
  already analyzed as not implicated.

## 5. Verification plan

1. **Regression check (mechanism)**: re-run `tools/test-reconnect-e2e.sh`
   and the disconnect/hide-then-restore `drmdump` polling test from
   earlier tonight -- confirm hide-then-restore still works pixel-correct
   after deferring it (this is the "no regression on the ORIGINAL fix"
   check).
2. **Positive check (the actual bug)**: this is a *latency* regression
   under real AirPlay client timing that `-replay` cannot faithfully
   reproduce (matches this project's established "wrong test harness"
   pattern for anything timing-sensitive). Cannot be fully closed out
   without the user testing a real seek/reconnect and confirming audio
   resume latency feels back to the ~1-2s baseline, not >3s. State this
   plainly rather than declaring it fixed unilaterally.
3. Once confirmed: commit with an explicit note of which revision fixed
   it (this file gets a "Fixed in" line filled in, plus a PROGRESS.md /
   memory update per protocol step 5).

## Fixed in

*(not yet fixed -- fill in commit hash(es) here once applied and
confirmed)*
