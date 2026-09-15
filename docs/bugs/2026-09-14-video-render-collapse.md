# Video freezes on first frame, forever (real client, non-native resolution)

Status: **RESOLVED, confirmed on real hardware (2026-09-14/15).** Watchdog
auto-recovery deployed and verified live, twice, on a freshly-flashed
card (the exact "first experience" scenario this was reported against).
A candidate root-cause mitigation (`-bt709`) was tested and **rejected**
-- a reproducible test proved it made no measurable difference, contrary
to an earlier, wrong impression from a single live session.

## Symptom

First live AirPlay session ever run against a freshly-flashed card: video
froze on the first frame and never recovered. Audio kept working. The
same server process, still running, froze on a second connection attempt
too. Killing the process and starting a fresh one made the very next
connection work.

## Investigation

Root-caused via a properly-armed `-capture` session (fixed a permissions
mistake on the first attempt -- the capture directory was root-owned, so
the unprivileged `uxplay` user's `-capture` file write silently failed;
the session still "worked" without recording anything) plus
`GST_DEBUG=kmssink:6,v4l2videodec:5`:

1. Decoder negotiates a real, non-native resolution (this client:
   1662x1080), decodes the first several frames fine.
2. `v4l2h264dec` fires `V4L2_EVENT_SOURCE_CHANGE` ("Received resolution
   change") a handful of frames in -- same width/height/format, only the
   colorimetry tag differs (Apple's encoder settling on its real value a
   few frames into the stream; this project's code already had a comment
   documenting this as a known, longstanding quirk before this bug was
   ever found). This forces a full `kmssink` renegotiation.
3. Exactly one frame renders under the new negotiation.
4. From there on: `v4l2h264dec` keeps decoding (100+ frames logged, zero
   errors) but `gst_kms_sink_import_dmabuf` never fires again. Decode and
   render have desynced -- almost certainly a stale prime-id/framebuffer
   cache collision inside `kmssink`'s own dmabuf-import bookkeeping
   across the two negotiation cycles (its own log showed reused prime
   ids across the decoder's small buffer pool).

This lives inside vendored GStreamer plugin internals (`kmssink`/
`v4l2videodec`), not code this project builds from source -- a from-
source patch is out of scope for this build pipeline (see
`build/vendor-gstreamer/`). It also matches a bug class this project's
own tooling had already flagged as unreproduced-by-synthetic-capture
(`tools/captures/README.md`, written well before this bug: "a real
client's non-native-resolution content triggered a render-rate
collapse").

## Fix: render-health watchdog (`UxPlay/renderers/video_renderer.c`,
`UxPlay/uxplay.cpp`)

Two always-on buffer-count probes per video pipeline (same attachment
pattern as the existing `av_sync_probe`, but counting only, no per-buffer
content inspection): one on the decoder's src pad, one on the sink's sink
pad. A new `render_health_callback` (same `GMainLoop` timeout pattern as
the existing `feedback_callback`) checks every second: if decode has
advanced but render hasn't, for 3 consecutive seconds, that's the
collapse signature -- log it and force the exact same full pipeline
relaunch the client-silence path (`-reset N`) already uses.

Deliberately a **detect-and-recover** fix, not a root-cause GStreamer
patch: `-reset N`'s existing recovery only fires after N seconds of
*client* silence (default 60s), which may never happen here since audio
keeps flowing fine even while video is stuck. 60+ seconds of a frozen
picture on someone's first AirPlay attempt is exactly what needed fixing.
Opt-out: `-norenderhealthcheck` (default: on), matching this project's
existing `-nofreeze`/`-nohold` escape-hatch convention.

Why a full pipeline relaunch reliably clears the stuck state without
needing to understand kmssink's exact internal bug: it tears down and
recreates every pipeline element from scratch (fresh decoder instance,
fresh sink instance, fresh internal caches). The empirical evidence
already showed this directly -- two stalls in a row on one long-lived
process, immediately fixed by a fresh process. A full pipeline rebuild is
a lighter-weight version of the same reset.

## Rejected: `-bt709`

Given the trigger is a colorimetry-only renegotiation, forcing the H.264
caps' colorimetry to a constant value via the pre-existing (opt-in,
off-by-default) `-bt709`/`capssetter` mechanism looked like a plausible
way to prevent the renegotiation from ever firing. One live test with it
enabled showed a clean session with no watchdog trigger, which looked
like confirmation.

**It wasn't.** Built `tools/test-resolution-change-gap-e2e.sh` (see
below) specifically to check this without relying on how a session
*felt*: replayed the same fixture with and without `-bt709` across
multiple real captures. Baseline gaps (frames decoded before render
resumes, after the resolution-change event): 0, 0, 0, 0, 1, 1, 1, 2. With
`-bt709`: 0, 0, 0, 0, 0, 1, 2, 2, 2. No consistent improvement -- if
anything, slightly worse on a couple of captures. The one clean live
session was noise, not signal. `-bt709` is **not** part of the shipped
config.

## The remaining micro-glitch (not a regression, not this bug)

After the watchdog fix, live testing showed a brief (~1-3 frame, well
under 100ms) visual hiccup during the one normal resolution-change
renegotiation every session goes through -- initially reported as "a
regression". It isn't: reproduced identically on the **original,
unmodified pre-watchdog binary** (confirmed both live, by deliberately
restoring the exact original binary+config and re-testing, and via the
reproducible test above, which measures the same 0-2 frame gap on
un-vendored, un-patched code). This is the ordinary, apparently mostly
unavoidable cost of a real mid-stream kmssink/v4l2videodec renegotiation
-- present before any of this investigation started, just never
precisely measured until now.

## Reproducible tests added

- `tools/trim-capture.py` -- trims any `-capture` `.cap` file to its
  first N seconds at a record boundary (the format has no header/index,
  so this is always safe). The resolution-change event, and apparently
  any render-path anomaly it triggers, happens within the first second
  of a real session -- there was nothing a multi-minute replay caught
  that its first few seconds didn't.
- `tools/captures/resolution-change-gap-repro.cap` (372KB, 1s, committed
  -- see `tools/captures/README.md`) + `tools/test-resolution-change-gap-
  e2e.sh` -- deterministic, ~14s round trip (was ~90s against the 39MB
  source capture). Measures the exact frame gap after the resolution-
  change event; fails loudly if the event doesn't fire at all (fixture or
  args broke the repro) or if the gap is `NEVER` (the collapse this bug
  report was about).
- `tools/captures/trimmed/*.cap` (10s trims of the full local corpus,
  committed) + updated `tools/test-render-health-e2e.sh` (now defaults to
  these) -- full 10-capture suite in ~4 minutes instead of many multiples
  of that; spot-checked against the full-length originals first to
  confirm trimming doesn't change the measured render/decode ratio.

## Real hardware confirmation

Reproduced live, twice, on a freshly-flashed card (matching the original
report exactly): forever-frozen video, audio fine, confirmed via a
properly-armed capture and GST_DEBUG trace (see Investigation above).
Deployed the watchdog fix, rebooted fresh, tested live twice more:
forever-freeze gone both times: either no collapse at all, or (when the
underlying renegotiation glitch does happen) a brief, self-healing hiccup
instead of a permanent freeze. Watchdog never even needed to fire in
these particular sessions -- the renegotiation itself resolved within its
normal small gap.

`-bt709` was tested live, found to help by impression, then proven not to
help by the reproducible test above -- not shipped. The remaining
micro-glitch was isolated to the pre-existing, un-vendored,
un-patched original code via both a live A/B (restoring the exact
original binary+config) and the reproducible test -- confirmed not a
regression from this fix.
