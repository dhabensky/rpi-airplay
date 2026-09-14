# Audio resume latency on seek/scrub (target: <=0.5s, observed: up to 3s)

Status: **root cause for the server-controllable portion identified and
ruled out as a defect; the reported worst case (up to 3s) is not
attributable to anything this server's code controls.** A synthetic,
repeatable Docker-based measurement (`tools/test-audio-reconnect-latency-e2e.sh`,
2026-09-14, see "Synthetic measurement" below) confirms and extends the
one real capture's finding across 34+ back-to-back reconnect cycles with
no artificial gap: server-side TEARDOWN(96)->SETUP(96)->audio-flowing-again
processing is stable at ~0.20-0.24s, does not grow or degrade across
repeated cycles, and the full reconnect time tracks almost exactly
(client/protocol-paced gap + this constant) in both the real capture and
the synthetic harness. No fix was written because no server-side defect
was found — see "Fixed in" below for what that means concretely.

## Requirement

User-reported: audio lag after seeking/scrubbing a video during mirroring
should be <=0.5s. Currently observed up to 3s. User's own hypothesis: "I
suspect it's related to how audio threads are killed and recreated
internally."

This is a **different** investigation from
`2026-09-13-audio-resume-latency-after-teardown.md`: that doc's root cause
(`video_renderer_hide_video()`'s synchronous DRM call blocking the httpd
thread's TEARDOWN response) cannot be active today -- that whole feature
was reverted and is confirmed absent from the current codebase (`grep -rn
"video_renderer_hide_video"` returns zero matches). This doc supersedes it
as the live investigation for audio-resume latency; the old doc is kept for
its own historical record per this project's documentation conventions.

## Method

`-replay` cannot exercise this bug class at all: it bypasses `lib/httpd.c`/
`lib/raop.c` entirely, feeding `video_process()`/`audio_process()` directly
from one thread, so it can't produce or measure a real RTSP TEARDOWN/SETUP
round trip. Used a real capture instead: stopped `uxplay.service`, ran the
same binary manually with the exact same flags as `uxplay.service`'s
`ExecStart=` plus `-d -capture <file>`, and had the user mirror + seek 3-4
times in one live session (`build/logs/audio-resume-latency-20260914.log`,
69,323 lines; paired `.cap` file also pulled down, both gitignored per the
existing `*.cap`/`build/` convention).

## What the capture actually contains

Across the whole session (multiple seeks): only **one** RTSP `TEARDOWN`
event total, and it was `96=1, 110=0` (audio-only), not `110` (video/
mirror) as the old bug doc's scenario assumed. Full HTTP method tally for
the session: `2 GET, 25 POST, 1 RECORD, 4 SETUP, 1 TEARDOWN`. All POSTs
were `/fp-setup` (x2, initial handshake) or `/feedback` (x23, ~1s
keepalive) -- no seek-specific endpoint exists at the RTSP layer. **Zero**
`FLUSH` requests anywhere in the log. **Zero** occurrences of `audio ntp <
base_time; re-basing audio clock` (the seek/reconnect PTS-rebase path in
`renderers/audio_renderer.c:458`) despite this being `LOGGER_DEBUG`-level
and debug logging being confirmed active (other `LOGGER_DEBUG` lines from
the same file, e.g. the startup pipeline dump, are present). **Zero**
`gst_app_src_push_buffer failed` self-heal triggers.

This means: of the user's 3-4 seeks in this session, only one produced any
trace at the RTSP/audio-pipeline layer at all. The other 2-3 left no
footprint in any mechanism this investigation checked -- most likely
handled entirely inside the video RTP/H.264 stream (IDR re-sync) with
audio continuing uninterrupted, though this wasn't directly confirmed.

## Timeline of the one captured TEARDOWN(96)+SETUP cycle

All timestamps from the `raop_rtp video: now = ...`/`raop_rtp audio: now =
...` lines (the only per-line timestamps in this raw, non-journald log;
video packets arrive continuously enough to bracket the RTSP-only lines
that have no timestamp of their own). Log line numbers refer to
`build/logs/audio-resume-latency-20260914.log` from this specific capture.

| Event | `now` (approx) | Source |
|---|---|---|
| Last video packet before TEARDOWN request | 1789378030.836 | line ~7712 |
| `TEARDOWN request, 96=1, 110=0` logged | (no timestamp; brackets to ~1789378030.85) | line 7746 |
| `raop_rtp exiting thread` (raop_rtp_stop() completes) | same bracket | line 7747 |
| TEARDOWN `200 OK` sent (`Connection: close`) | same bracket | line ~7752 |
| First video packet after the response | 1789378030.872 | line 7754 |
| Last video packet before the next SETUP request | 1789378031.573 | line 7796 |
| New SETUP request arrives (audio, type=96) | (brackets to ~1789378031.58) | line 7782 |
| `restarting audio connection, format AAC-ELD 44100/2` | same bracket | line 7837 |
| `raop_rtp start_time` (new audio RTP session) | 1789378031.599077 | line 7842 |
| SETUP `200 OK` sent | same bracket | line ~7848 |
| First real audio RTP packet decoded | 1789378031.911931 | line 7906 |

**Gap breakdown**:
- TEARDOWN `200 OK` (~1789378030.86) -> next SETUP request (~1789378031.58):
  **~0.71s**. Video streamed continuously and normally through this whole
  window (frame-to-frame gaps stayed at the normal ~30-35ms, confirming
  the server did nothing slow here) -- this gap is **entirely
  client-paced**: the client (macOS AirPlay sender) decides on its own
  when to re-issue SETUP after a TEARDOWN, and our TEARDOWN response
  unconditionally includes `Connection: close`
  (`lib/raop_handlers.h:1283`, sent for every teardown type, not just
  `96` -- confirmed pristine/unmodified from upstream FDH2/UxPlay, not
  something this fork added), which is standard AirPlay/RAOP protocol
  behavior instructing the client to open a fresh TCP connection before
  its next request.
- SETUP request -> first real audio RTP packet (~1789378031.58 ->
  ~1789378031.91): **~0.31s**. Confirmed server-side work in this window
  is cheap: `raop_rtp_stop()`'s `THREAD_JOIN` completes within one 5ms
  `select()` timeout cycle (`lib/raop_rtp.c:419-421`), and
  `audio_renderer_start()` hit the **same-codec restart** branch
  (`renderers/audio_renderer.c:378-385`) since the codec (AAC-ELD, ct=8)
  didn't change across the reconnect -- this branch does **not** tear
  down or rebuild the GStreamer pipeline at all, just refreshes
  `gst_audio_pipeline_base_time`. No pipeline NULL->PLAYING cycle, no ALSA
  device reopen. The ~0.31s is dominated by the client's own pacing of
  when it starts sending audio RTP packets after seeing the SETUP
  response, not server work.
- **Total measured gap**: ~1.0-1.05s from TEARDOWN response to first
  audio packet. Real, but already under half the reported 3s worst case.

## Mechanisms checked and ruled out

- **`raop_rtp_stop()`'s thread join blocking the httpd thread for a long,
  variable time** (the user's own "threads killed and recreated"
  hypothesis, and this investigation's strongest early lead): the audio
  RTP thread's `select()` timeout is 5ms (`lib/raop_rtp.c:421-422`), and
  `raop_rtp_process_events()` is checked every loop iteration
  (`lib/raop_rtp.c:417-419`) -- worst-case join time is ~5-10ms, confirmed
  by the capture itself (video kept streaming normally with no stall
  around the TEARDOWN).
- **`video_renderer_blank_display()`'s up-to-~4s join
  (`video_renderer_join_pending_blank()`, `renderers/video_renderer.c:
  909-913`, called from `video_renderer_init()`)**: real and genuinely
  slow (the code's own comment documents "up to ~4s in the worst case"),
  and would block whatever thread calls a subsequent
  `video_renderer_init()` -- but per `docs/video-pipeline.md`'s state
  machine, this only runs on the **slow/eventual path**
  (`feedback_callback`'s `-reset N` timeout, default 60s, or an explicit
  `close_window`/`full_video_reset`), never on an ordinary seek's
  RTP_SHUTDOWN, which takes the **fast path** (`skip_video_rebuild=true`,
  pipeline stays alive, no `video_renderer_destroy()`/`_init()` cycle at
  all). Ruled out for the seek scenario specifically.
- **PTS-rebase-on-seek path** (`renderers/audio_renderer.c:458`,
  `LOGGER_DEBUG`): zero occurrences in the whole session despite multiple
  seeks -- not exercised by whatever this client did.
- **Self-heal-on-push-failure** (`renderers/audio_renderer.c:518-528`):
  zero occurrences.
- **`Connection: close` being something this fork could safely drop**:
  it's unconditional, unmodified upstream behavior
  (`lib/raop_handlers.h:1283`, present for every TEARDOWN type). Changing
  this is standard-AirPlay-protocol-incompatible territory -- real risk of
  breaking other real Apple devices that rely on this semantics, untested
  and untestable without broad real-device coverage this project doesn't
  have. Not attempted.

## Synthetic measurement (2026-09-14, `tools/test-audio-reconnect-latency-e2e.sh`)

The real capture above is one event; to check whether a rare, slow
server-side outlier exists that a single live session just didn't happen
to hit, `-threadtest` (`docs/threadtest.md`, already drives the real
`httpd.c`/`raop.c` stack with real RTSP requests over loopback, no
hardware needed) was extended with a per-cycle real RTCP sync packet
(needed for any audio packet to ever be dequeued and rendered at all --
`raop_rtp.c`'s `initial_sync` cold-start guard, previously undiscovered
because `-threadtest` never sent one) and a `RECV-TEARDOWN-response`
timestamp marker (`UxPlay/uxplay.cpp`'s `threadtest_driver()`, both
changes confined to that function, only reachable via `-threadtest`,
zero effect on any production code path).

Two runs, entirely in Docker:
- **50 cycles, zero inter-cycle gap** (hunts for growth/leaks across many
  more reconnects than one real session shows): 33 of 34 measured cycles
  (1 isolated cycle produced no data at all -- a lost synthetic UDP sync
  packet, this driver's own known limitation, not a measured slow
  latency) landed at **mean 0.22s, max 0.24s** -- stable across the whole
  run, no growth, no late-run slowdown.
- **10 cycles, 1s inter-cycle gap** (approximates the real capture's
  ~0.71s client-paced gap, reported informationally, not gated against
  the 0.5s target since the inserted gap is deliberately the
  not-server-controllable portion): **mean 1.23s, max 1.24s** -- almost
  exactly (inserted gap + the zero-gap run's own ~0.22s), confirming the
  zero-gap run's numbers are representative of real-world scale rather
  than an artifact of loopback timing.

This directly answers what the one real capture couldn't: across 34+
consecutive reconnect cycles, server-side TEARDOWN(96)->SETUP(96)
processing never spikes, never drifts, and stays comfortably under the
0.5s target on its own. Combined with the real capture's own finding
(server processing there was ~0.31s, also cheap, also the same-codec
restart branch with no pipeline rebuild), there is now strong,
repeatable evidence -- not just one sample -- that the server-controllable
portion of this reconnect is not the source of the reported up-to-3s lag.

## What this investigation did NOT explain

- **The reported worst case is ~3s; the highest measured value anywhere
  in this investigation (real capture or synthetic, zero-gap or
  1s-paced) is ~1.24s.** Nothing found here reproduces a 3s gap.
- **What the other 2-3 seeks in the real capture's session actually
  did.** They left zero trace in every mechanism checked (RTSP requests,
  PTS-rebase, self-heal). If they were audible-lag-free, that would mean
  only *some* seeks trigger the TEARDOWN/SETUP renegotiation path at
  all, and the open question becomes "what decides whether the client
  does that" -- entirely client-side logic, opaque to this server.
- **A `teardown_110` (video/mirror) reconnect was never captured or
  synthetically driven.** If the client sometimes tears down *video*,
  not just audio, on a seek, that's a structurally different path
  (`RESET_TYPE_RTP_SHUTDOWN` through the *fast* path, per
  `docs/video-pipeline.md`'s state machine) this investigation has not
  measured end-to-end -- `-threadtest` is audio-only (`-vs 0`) by design
  (no DRM/v4l2h264dec needed), and driving a synthetic H.264 mirror
  stream through `raop_rtp_mirror.c` would be substantially more work
  than the audio-only driver extension done here.
- Given ~0.71s of the real capture's ~1.0s measured gap is client-paced
  and protocol-mandated (`Connection: close`, unconditional, unmodified
  upstream behavior -- not fixable here without a real
  protocol-compliance risk), and every server-side measurement taken
  (real and synthetic, one sample and 34+ samples) stays well under the
  0.5s target on its own, **there is no concrete, low-risk server-side
  change identified that would move any measured gap materially closer
  to explaining a 3s worst case** -- because nothing measured here comes
  close to 3s in the first place.

## Candidate next steps (not yet decided)

1. Investigate whether anything server-side influences the client's
   choice between "smooth" seeks (no RTSP event, the majority of what was
   observed in the real capture) and a full audio TEARDOWN+SETUP
   renegotiation (the minority, and the only kind that produces an
   audible gap at all as far as this investigation found) -- if that
   choice can be nudged, the actual fix might be "make the client not
   need to renegotiate," not "make the renegotiation faster."
2. Extend the synthetic harness to drive a `teardown_110`/video-mirror
   reconnect (substantially more work: needs a synthetic H.264 RTP mirror
   stream through `raop_rtp_mirror.c`, not just audio) to rule that path
   in or out the same way this investigation ruled out the audio-only
   path.
3. Get a live capture aimed specifically at reproducing the worst case
   (e.g. seek twice in quick succession, or seek during heavier video
   load) rather than a general "mirror and seek a few times" session --
   the one real capture available happened to only catch a mild ~1.0s
   instance.
4. Accept the <=0.5s target as met for the mechanism actually measured
   here (server-side audio-only reconnect processing), and treat the
   worst-case 3s report as pointing at a mechanism outside what this
   investigation covered (client-side pacing, a video/mirror-specific
   path, or something not yet captured at all).

## Fixed in

No code fix was made -- none is evidenced. What *was* delivered:
`UxPlay/uxplay.cpp`'s `threadtest_driver()` extended with real sync
packets + a `RECV-TEARDOWN-response` marker (test-only, confined to that
function), and `tools/test-audio-reconnect-latency-e2e.sh` (new),
committed as a permanent regression guard against a *future* change
introducing slow server-side reconnect processing on this specific path
-- distinct from resolving the user's reported symptom, which remains
open per "Candidate next steps" above.
