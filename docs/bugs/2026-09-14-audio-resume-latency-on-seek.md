# Audio resume latency on seek/scrub (target: <=0.5s, observed: up to 3s)

Status: **RESOLVED, confirmed on real hardware (2026-09-14).** Two fixes:
the first was real but insufficient (deployed, confirmed via a real
capture to have zero effect on the reported symptom); the second is what
actually bounds the dropout duration, and was confirmed live: "looks
fixed" after redeploying and a long real mirror+seek session. See "Real
hardware confirmation" below for the full close-out, including a
follow-up "regression" report that turned out to be a diagnostic-tooling
artifact, not a real bug.

**Fix #1 — resend-request rate limiting** (`RAOP_RESEND_MIN_INTERVAL_NS`,
`lib/raop_buffer.c`, 100ms): `lib/raop_buffer.c`'s resend-request logic
had no rate limiting at all — every ~5ms main-loop tick, for as long as
an audio packet stayed missing, it fired a brand new duplicate resend
request at the client, with no memory of having just asked. Confirmed via
a real capture: ~760 duplicate requests per ~2.8s real audio dropout.
Deployed, then redeployed after a mistake (an orphaned diagnostic process
left the mDNS registration held, causing the real service to fail to
start — unrelated to the fix, fixed by killing the stray process).
**The user tested it and reported "no effect".** A fresh capture with the
fix active confirmed why: request volume *was* down (~27 requests vs the
unfixed ~760, matching the fix's design), but the actual dropout was
still ~2.8s, unchanged. The rate limit is real and worth keeping (less
redundant control-channel traffic during an already-congested window),
but it was never the actual bottleneck.

**Fix #2 — stall-timeout force-skip** (`RAOP_STALL_TIMEOUT_NS`,
`lib/raop_buffer.c`, 200ms) — **this is the one that matters**. Traced
directly from the "no effect" capture: `raop_buffer_handle_resends` showed
`first_seqnum` stuck for the entire ~2.8s window while `last_seqnum`
climbed until it landed exactly on `first_seqnum + 256`
(`RAOP_BUFFER_LENGTH`). `raop_buffer_dequeue()` only force-skips a stuck
missing packet once the buffer's full 256-entry capacity is exhausted —
completely independent of resend request rate. At AAC-ELD's real cadence
(spf=480 @ 44100Hz ≈ 10.9ms/packet), filling 256 entries takes
256 × 10.9ms ≈ 2.79s, matching the observed ~2.8s almost exactly. Fixed by
adding a *time*-based force-skip, orthogonal to the existing capacity-based
one: once a slot has been stuck for `RAOP_STALL_TIMEOUT_NS` (200ms), skip
it regardless of buffer capacity. `RAOP_BUFFER_LENGTH` itself is
unchanged (still 256) — upstream raised it there specifically to fix ALAC
stuttering (issue #526), so shrinking it back risked reintroducing that;
the time-based fix leaves ordinary jitter/reordering (resolves in
single-digit-to-tens of ms) completely unaffected. Verified via the same
`-resendstormcheck` driver, corrected to send its synthetic keepalive
stream at AAC-ELD's real ~10.9ms cadence (an earlier, faster, arbitrary
5ms interval had under-predicted the real-world stall by ~2x — 1.27s
synthetic vs ~2.8s real): **~2.72s before this fix (matching the real
capture almost exactly), ~0.10-0.11s after, three consecutive runs.**

Both fixes are pristine-upstream-behavior-turned-fork-specific-fixes —
neither existed as a defense in `FDH2/UxPlay` upstream. See "Fix
implemented" sections below for full detail on each.

The earlier TEARDOWN(96)+SETUP investigation below is still accurate on
its own terms (that mechanism is real, but minor, and was not the
dominant contributor the user was actually hearing) — kept for reference.

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

## Second live capture: the real mechanism (2026-09-14)

The TEARDOWN(96)+SETUP investigation above answered "how fast does an
audio reconnect resolve" -- but per "What this investigation did NOT
explain," it never reproduced anything close to 3s, and most seeks left
no RTSP-layer trace at all. The user pushed back explicitly: multiple
real audio dropouts happened during a single mirror+seek session, all
before "done" was said -- meaning they were not being missed for lack of
a capture, they were being missed by only looking at the RTSP layer.

**Methodology fix, worth recording**: a first re-capture attempt this
session was cut short by killing the process ~2.9s after the one
TEARDOWN(96) event, before the next SETUP had arrived -- an own mistake,
not a null result (the capture proved nothing either way, since the
window that mattered was cut off). Second attempt kept running normally
until the user said "done" with no early kill.

**What actually happened, found by searching the raw RTP packet timeline
directly instead of only RTSP request/response lines**: extracting every
`raop_rtp audio: now = ...` timestamp from the whole session
(`build/logs/audio-resume-latency-20260914b.log`, 3643 audio RTP lines)
and computing gaps between consecutive ones surfaces three, and only
three, outliers -- everything else is sub-150ms jitter:

| Gap | Real elapsed | seqnum before -> after |
|---|---|---|
| t=1789385443.461 -> 1789385446.285 | 2.824s | 21269 -> 21276 |
| t=1789385451.612 -> 1789385454.422 | 2.810s | 22020 -> 22023 |
| t=1789385462.353 -> 1789385465.210 | 2.857s | 23008 -> 23015 |

Three real, roughly-3-second audio gaps in one session -- matching the
reported symptom almost exactly, both in count (user described multiple
dropouts) and in duration (each right at ~2.8s, not the milder ~1s the
TEARDOWN investigation found). **Zero RTSP events accompany any of the
three** -- no TEARDOWN, no SETUP, no FLUSH; this is the same connection,
same RTP session, throughout. **Video kept streaming normally the entire
time** (84-86 video packets landed inside each gap window, with normal
~30-120ms inter-packet spacing, confirmed by directly counting `raop_rtp
video: now = ...` lines falling strictly inside each window) -- ruling
out a client-side "whole pipeline paused to rebuffer" theory; if the
client's media pipeline had stalled, video would have stalled too.

**The actual mechanism, read directly from `lib/raop_buffer.c`/
`lib/raop_rtp.c`**: a handful of audio UDP packets (7-8 sequence numbers'
worth) were lost in transit -- very plausibly to the same WiFi congestion
the seek's own large H.264 I-frame burst creates (the video packets
immediately preceding each gap run 10-77KB, dwarfing the ~1-2KB steady
state). `raop_buffer_dequeue()` (`lib/raop_buffer.c:229`) refuses to
return *anything* past the first missing sequence number -- correct,
in-order delivery is required for AAC-ELD -- so nothing plays until that
one packet arrives, no matter how much later audio has already arrived
behind it. So far this is reasonable, expected jitter-buffer behavior for
a lossy network.

**What isn't reasonable**: `raop_buffer_handle_resends()`
(`lib/raop_buffer.c:270`) is called unconditionally on *every* iteration
of the main RTP thread's `select()` loop
(`lib/raop_rtp.c:637`, and that loop's own timeout is 5ms,
`lib/raop_rtp.c:421-422`) -- and every single call, with zero memory of
having just asked, fires a **brand new** resend-request packet at the
client (`raop_rtp_resend_callback()`, `lib/raop_rtp.c:199`, a fresh
`ourseqnum` each time, no rate limit, no backoff, no deduplication).
Confirmed by direct count: **all three gaps show ~760-762
`raop_buffer_handle_resends` log lines** (matches 2.8s / 5ms almost
exactly) **and 1067-2798 `raop_rtp resent audio packet` lines** -- the
client dutifully answering hundreds of near-duplicate resend requests,
during the exact window WiFi is already congested from the seek's own
I-frame burst. This is pristine, unmodified upstream code
(`docs/upstream-comparison.md` confirms `lib/raop_rtp.c`'s only changes
are the redundant-SETUP port-0 fix and the NTP-sync-state reset, neither
touching this path; `lib/raop_buffer.c` has zero diff from upstream at
all) -- not something this fork introduced, but a real, fixable
receiver-side policy choice, not something the AirPlay wire protocol
mandates.

**Why this explains the ~2.8s duration specifically**: rather than one
clean request + a reasonable wait + a bounded number of retries, the
receiver is contributing its own flood of redundant control-channel
traffic into the exact congestion window that's already struggling to
deliver the original packets -- plausibly extending, not shortening, the
time to recovery. The eventual resolution look like a threshold effect
(the buffer's 256-entry capacity, `RAOP_BUFFER_LENGTH`,
`lib/raop_buffer.c:36`) rather than the resend logic converging: by the
end of each gap the buffer holds up to ~259 sequence numbers' worth of
backlog, right at that cap.

## Fix implemented

`lib/raop_buffer.c`: `struct raop_buffer_s` gained three fields
(`last_resend_requested`, `last_resend_first_seqnum`,
`last_resend_request_ns`), and `raop_buffer_handle_resends()` now checks,
before firing `resend_cb`: if the current gap's `first_seqnum` matches the
last request's and fewer than `RAOP_RESEND_MIN_INTERVAL_NS` (100ms) have
passed since then (via `clock_gettime(CLOCK_MONOTONIC, ...)`, self
contained -- this file has no other dependency on `raop_ntp.h`'s clock),
skip firing this call. A genuinely new gap (`first_seqnum` changed --
either this one resolved and a new one opened, or the buffer advanced)
always fires immediately, matching pre-fix behavior exactly for the
*first* request. Zero public-signature changes (`raop_buffer_handle_resends()`'s
declaration in `lib/raop_buffer.h` is unchanged), so the one call site
(`lib/raop_rtp.c:637`) needed no changes at all.

**New test infrastructure**, since `-threadtest`'s existing driver
deliberately runs with `controlPort=0` (skips the resend-wait path
entirely, see `docs/threadtest.md`) and so cannot exercise this at all:
a new scripted-client mode, `-resendstormcheck`
(`threadtest_resend_storm_check()`, `UxPlay/uxplay.cpp`, same
completion-then-exit pattern as `-ntpresynccheck`). It declares a real,
non-zero `controlPort` (binds its own local UDP socket first, puts that
port in the SETUP request, and sends its sync packet from that exact
socket so the server learns where to route resend requests -- it reads
the *source address* of the first control-channel packet it receives,
not the SETUP body directly), creates a permanent 3-packet gap (seqnums
5-7, never sent to anyone), then sends one keepalive packet roughly every
5ms for 1 second while counting distinct resend-request packets received
back. New `tools/test-audio-resend-storm-e2e.sh` drives it and asserts
the count stays under 30 (see "Verification" below for the actual
numbers -- 30 sits with wide margin either side of both).

**Bug-fix-protocol compliance**: built and ran `-resendstormcheck`
against the pre-fix tree by hand first (three separate runs) --
consistently **200 duplicate requests in 1s for 200 packets sent, a
1:1 ratio**, positively confirming the flood exists and matches the real
capture's own ~1:1-ish ratio (~760 requests for a comparable window of
packet/response activity). After implementing the fix, the same check
(three more runs) consistently showed **10 requests in 1s** -- exactly
matching the math (1000ms / 100ms interval = 10), a clean 20x reduction,
with the *first* request for the gap still firing immediately in every
run (confirmed via the log's `SENT-GAP` marker timing relative to the
first counted request).

## Verification

- `-resendstormcheck` manually against pre-fix code: 200, 200 (two runs,
  see above for a third).
- `-resendstormcheck` against the fix: 10, 10, 10 (three runs).
- `tools/test-audio-resend-storm-e2e.sh` (new): PASS against the fix
  (count=10, threshold=30).
- `make unit-tests`: PASS, unaffected (this fix doesn't touch either
  tested path).
- `tools/test-audio-ntp-resync-e2e.sh`: PASS, unaffected (same driver
  infrastructure file, different mode, confirmed unchanged).
- `tools/test-audio-reconnect-latency-e2e.sh` (from earlier the same
  day): PASS, unaffected.
- **End-to-end recovery-time comparison** (`-resendrecoverycheck`,
  `docs/threadtest.md`, manual one-off verification, prompted by a fair
  challenge that request-count alone doesn't prove faster recovery):
  against pre-fix code (`lib/raop_buffer.c` temporarily reverted,
  rebuilt, restored after), the same synthetic gap+channel-contention
  scenario doesn't resolve via a clean resend at all -- `RAOP_BUFFER_LENGTH`'s
  256-entry cap force-flushes the buffer at ~1.27s, silently discarding
  the missing content (253 keepalive packets at 5ms predicts 1.265s,
  matching almost exactly). This lines up with the real capture too: by
  the end of each real ~2.8s dropout, the buffer's backlog had grown to
  ~259 sequence numbers, right at this same cap -- suggesting the real
  dropouts likely ended the same way (a silent content drop, not a
  successful resend). Against the fix, the identical scenario resolves
  via a genuine clean resend in ~10ms on the first request, three
  consecutive runs (recovery times 0.0102s/0.0102s -- effectively
  identical). Graphs generated and shown to the user directly (not
  committed -- one-off diagnostic images, `build/audio-viz/`,
  gitignored).
- **Not done, explicitly deferred**: a real `-d -capture` session on the
  actual Pi confirming the ~2.8s dropouts observed in the second live
  capture actually stop happening. The user is away from home; this is
  the one thing every synthetic test here cannot substitute for, and
  isn't being glossed over as "done" until it happens.

## Deployed, tested, "no effect" — the real second root cause

Fix #1 was deployed live via SSH (checksum-verified) and the service
restarted. A deployment sequencing mistake surfaced first: an orphaned
`-d -capture` process from an earlier, interrupted session (the Pi went
offline mid-session when the user left home) was still running and held
the mDNS registration, causing the freshly-deployed service to fail to
start (`kDNSServiceErr_NameConflict`) -- unrelated to the fix itself,
fixed by killing the stray process.

Asked the user to test; **they reported "no effect"** before a capture was
armed -- a second sequencing mistake (should have armed the capture
*first*). Re-armed, asked for one more repro, this time bracketing it
properly (waited a real margin after "done" before stopping, learned from
an earlier premature-stop mistake the same day).

The fresh capture (`build/logs/resend-fix-verify-20260914.log`) confirmed
the report: `raop_rtp audio: now = ...` timestamps show two real gaps,
2.8197s and 2.8155s, plus a 1.4587s one. **Fix #1 was confirmed active**
(`raop_buffer_handle_resends` fired ~762 times per gap as before, but only
~27 real `raop_rtp got resend request` lines -- the rate limit working
exactly as designed, ~30x fewer actual requests) -- **and the dropout
duration was completely unchanged.** This directly disproved the
"flooding extends recovery" hypothesis fix #1 was based on: cutting
request volume 30x had zero effect on how long the stall lasted, meaning
request volume was never the controlling variable.

Tracing `first_seqnum`/`last_seqnum` through the `raop_buffer_handle_resends`
log lines in this window found the real mechanism (fix #2, above):
`first_seqnum` stayed at 35455 for the whole ~2.8s while `last_seqnum`
climbed to exactly `35455 + 256`, at which point `first_seqnum` finally
advanced (by one, then by one more) and the dropout ended. This is
`raop_buffer_dequeue()`'s capacity-based force-skip, not a successful
resend -- confirmed a stuck packet keeps getting resent (27 "resent audio
packet: seqnum=35455" log lines) without ever being consumed until the
buffer fills.

## Real hardware confirmation (2026-09-14)

Fix #2 deployed the same way as fix #1 (checksum-verified via SSH), this
time with the capture armed *before* asking the user to test (the
sequencing mistake from fix #1's deploy, corrected). Long real
mirror+seek session (~316s, 5 seek-triggered reconnects) captured with
`-d -capture`. User's verdict: **"looks fixed."** Confirmed independently
in the capture: the largest gap anywhere in the whole session was 1.46s
(down from the original ~2.8-3s), and every genuine content-loss gap
(seqnum actually jumped, not just delayed) stayed under ~1.2s -- a real,
large improvement, though not a strict sub-500ms guarantee in every
possible case (see "Known remaining limitation" below).

**Follow-up report: "small audio stutter on long playback."** Analyzed
the same long capture, segmented by the 6 SETUP/TEARDOWN boundaries to
avoid comparing sequence numbers across unrelated sessions. Of 46 gaps
>=50ms across the whole session, 38 (83%) showed **no content loss at
all** (consecutive sequence numbers -- the packet arrived and dequeued
normally, just later than usual). `raop_buffer_dequeue()`'s stall-timeout
code only executes when a slot is genuinely empty, so these 38 cannot be
caused by fix #2 -- confirmed by reading the code, not just inferred from
the data. Only 8 gaps showed a real sequence-number jump (genuine
loss/skip, fix #2's actual mechanism), ranging 0.2-1.19s.

The user independently tested again on normal (non-captured) playback and
**could not reproduce the stutter**, and suggested the capture itself was
the cause. Confirmed in the code: `cap_write()` (`UxPlay/uxplay.cpp`) is
called synchronously from *both* the audio and video processing threads,
sharing one mutex, with a periodic `fflush()` every 50 combined
audio+video records (roughly every 0.3-0.4s at typical combined write
rates) -- a real, already-documented tradeoff in that function's own
comment (flushing every record was tried before and found "expensive
enough... to visibly lag live playback"; batching to 50 was the existing
mitigation, not eliminating the effect, just reducing its frequency).
This matches the data exactly: a shared-mutex disk-flush stall would
delay packet processing on the audio thread without ever dropping
content, precisely the "consecutive seqnum, just late" signature seen in
83% of the gaps. Confirmed `-capture` is diagnostic-only and never active
in normal operation (`image-builder/files/etc/systemd/system/uxplay.service`'s
`ExecStart=` has no `-capture` flag). **Conclusion: capture-tooling
artifact, not a regression from either fix; no production code change
needed for this report.**

## Known remaining limitation

Fix #2's 200ms stall timeout is a *check interval*, not a hard wall-clock
guarantee: it only gets re-evaluated when `raop_buffer_dequeue()` is
called, which only happens when the RTP thread's `select()` loop wakes on
real socket activity. If an entire burst of packets is lost together,
there can be a quiet stretch (nothing arriving at all) before the next
real packet wakes the thread and the already-elapsed timeout is noticed
-- observed directly in the confirmation capture: the two largest
genuine-loss gaps (0.75s and 1.19s, 38 and 68 packets lost respectively)
exceeded the nominal 200ms by a wide margin for this reason. Still a very
large improvement over the pre-fix ~2.8s in every observed case, but not
a strict sub-500ms bound under all real-world conditions. Not addressed
further as of this write-up -- flagged here rather than overclaiming a
hard guarantee that the mechanism doesn't actually provide.

## Fixed in

**Fix #1 (resend-request rate limiting), deployed and found
insufficient**: Main repo `e4a84f6` (fix + docs + new test), `a1778ba`
(submodule bump for incidental `-mp4` fixes). UxPlay submodule `5222900`
(the fix + `-resendstormcheck`), `9b2fffa` (incidental `-mp4` mux-to-file
fixes found while building a visualization), `59c5dcc`
(`-resendrecoverycheck`, later found to have modeled the wrong bottleneck
-- see `docs/threadtest.md`'s correction note). Main repo `635d28f`
(recovery-time verification writeup).

**Fix #2 (stall-timeout force-skip), the one that actually matters,
confirmed on real hardware**: Main repo `b87ce20`, UxPlay submodule
`c768aba`.
