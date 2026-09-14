# `-threadtest`: real multi-threaded server test tool

`-threadtest N` (`uxplay.cpp`) drives the real `raop_init()`/
`raop_start_httpd()` server over loopback with a minimal synthetic AirPlay
client, instead of `-replay`'s single-thread callback-injection model.
This exercises the real httpd thread, real `conn_request()`/
`raop_handler_setup()` dispatch, and a real per-connection
`raop_rtp_thread_udp` — none of which `-replay` ever touches (`-replay`
calls `video_process()`/`audio_process()`/`audio_renderer_start()`
directly from one feeder thread, bypassing `lib/httpd.c` and `lib/raop.c`
entirely).

## Usage

```
uxplay -vs 0 -threadtest N
```

- `-vs 0` disables video, so this runs without Raspberry Pi hardware (no
  DRM/v4l2h264dec needed) — audio-only, works in a plain Docker container
  or on the Pi.
- `N` is the number of SETUP/TEARDOWN cycles to run.
- `UX_THREADTEST_GAP_S=<seconds>` (env var): inter-cycle gap. The driver
  sends a `POST /feedback` keepalive at least every 2s during the gap, so
  gaps longer than the server's missed-feedback/`-reset` timeout (default
  15s) don't get the connection killed.
- `UX_THREADTEST_DIAG=1` (env var, also set automatically by `-threadtest`
  itself): enables timing/state print lines from both the driver and the
  server side (`TT_DIAG` macro, `renderers/audio_renderer.c`) — connection
  restart timing, deferred-callback execution timing, and a
  decode-buffer-count probe on the audio decoder's output pad.

## What the driver does

1. Connects via TCP to `127.0.0.1:<raop_port>`.
2. Sends a request carrying `CSeq` (classifies the connection as
   `RAOP`-type in `conn_request()`).
3. Performs the FairPlay handshake (`POST /fp-setup` twice) using
   `lib/fairplay.h`'s real `fairplay_setup()`/`fairplay_handshake()`/
   `fairplay_decrypt()` functions directly — the driver computes, offline,
   exactly what `aeskey` the server will derive for a chosen 72-byte
   `ekey` blob, by calling the same function itself.
4. For each cycle: sends a bplist SETUP request (the first cycle includes
   `ekey`/`eiv`/`deviceID`/`timingProtocol=None`; later cycles omit them,
   matching a real client's per-stream-only re-SETUP), parses the
   `dataPort`/`controlPort` out of the response, sends a real RTCP sync
   packet to `controlPort` (twice, 20ms apart, since this is a
   fire-and-forget UDP send with no ACK/retry — `raop_rtp.c`'s dequeue loop
   never dispatches anything to `audio_process()` until `initial_sync` is
   true, reset on every restart, so without this every audio packet below
   would sit in the jitter buffer forever), then sends real
   AES-128-CBC-encrypted RTP audio packets (a genuine captured AAC-ELD
   frame, `tt_real_aac_eld_frame`) to `dataPort`, then sends TEARDOWN.
5. `controlPort` is always `0` in the SETUP **request** (the client's own
   declared port, distinct from the server's `controlPort` in the
   response used for the sync packet above): a non-zero value there
   activates `raop_buffer_dequeue()`'s resend-wait path
   (`lib/raop_buffer.c:242-251`), which withholds every packet awaiting a
   genuine RTCP resend the driver never sends or answers.
6. Prints `SEND-SETUP`/`RECV-SETUP-response`/`SENT-SYNC`/
   `FIRST-AUDIO-PACKET`/`SEND-TEARDOWN`/`RECV-TEARDOWN-response`, each with
   a `tt_now()` timestamp and cycle number — used by
   `tools/test-audio-reconnect-latency-e2e.sh` (see below) to measure
   reconnect latency precisely.

## Known limitation

The driver sends one real captured AAC-ELD frame repeated (only
seqnum/timestamp incrementing) rather than a genuine continuous encoded
sequence. Confirmed empirically (2026-09-14, driving `-threadtest` with a
real sync packet for the first time — see below): the repeated,
per-packet-re-encrypted content consistently fails
`audio_renderer_render_buffer()`'s own frame-validity check (the decrypted
first byte doesn't match any of AAC-ELD's expected marker bytes), so it
never even reaches `gst_app_src_push_buffer()`, let alone the decoder —
`install_decode_probe()`'s `DECODED-BUFFER-OUT` marker
(`renderers/audio_renderer.c`) does not fire at all in practice with this
driver's traffic. `RENDER-BUFFER-CALL` (logged earlier in the same
function, before the validity check) is the reliable marker for "the RAOP
audio thread dequeued and handed off a synced packet" with this driver;
`tools/test-audio-reconnect-latency-e2e.sh` uses it for exactly this
reason. Diagnosing genuine decode failures needs a longer/varied real
captured sequence fed frame-by-frame instead.

## `-ntpresynccheck`: differential regression check

```
uxplay -vs 0 -ntpresynccheck
```

A second, narrower scripted-client mode (same connection/FairPlay/SETUP
machinery as `-threadtest`, different sequence): establishes a session and
a real RTCP sync packet, restarts (TEARDOWN+SETUP), sends one audio packet
*before* any new sync packet, then sends a fresh sync packet and a second
audio packet. Prints `SENT-PROBE-A`/`SENT-SYNC-2`/`SENT-PROBE-B` markers
and relies on `RENDER-BUFFER-CALL` (`renderers/audio_renderer.c`,
`UX_THREADTEST_DIAG`) for the rest. Runs to completion and exits on its
own (no long-lived server loop). Driven by
`tools/test-audio-ntp-resync-e2e.sh`, which builds the current working
tree and asserts the RTP-timestamp-to-NTP-time sync state reset in
`raop_rtp_start_audio()` behaves correctly (see `docs/audio-pipeline.md`).

## `-resendstormcheck`: resend-request rate-limit regression check

```
uxplay -vs 0 -resendstormcheck
```

A third, narrower scripted-client mode. Unlike every other mode here, it
declares a **real, non-zero `controlPort`** in its SETUP request (every
other mode uses `0`, which sets `no_resend=true` and skips the resend-wait
path entirely — see "What the driver does" above) — this is the only mode
that actually exercises `lib/raop_buffer.c`'s resend-request logic. Binds
its own local UDP socket first and puts that port in the SETUP request;
the server learns to route resend requests back to it from the source
address of the sync packet sent immediately after (`lib/raop_rtp.c`'s
`got_remote_control_saddr` handling reads the *source* of the first
packet arriving on its control channel, not the SETUP body directly, so
sending the sync packet from any other socket wouldn't work).

Sends audio packets 0-4, then permanently skips seqnums 5-7 (never sent,
to anyone), then keeps sending one packet roughly every 5ms for 1s while
counting distinct resend-request packets (8 bytes, `packet[1] == 0xD5`)
arriving back on its own socket. Prints `RESEND-REQUEST-COUNT <n> (in
1.0s, sent <n> keepalive packets)`. Runs to completion and exits on its
own. Driven by `tools/test-audio-resend-storm-e2e.sh`, which builds the
current working tree and asserts the count stays under a threshold well
below the unfixed 1:1 packet-to-request ratio — see
`docs/bugs/2026-09-14-audio-resume-latency-on-seek.md`.

## `-resendrecoverycheck`: end-to-end recovery-time comparison (no Pi/network needed)

```
uxplay -vs 0 -resendrecoverycheck
```

Same setup as `-resendstormcheck` (real `controlPort`, permanent 5-7 gap,
5ms keepalive stream), but this mode actually answers resend requests --
modeling a contended channel instead of a real lossy WiFi link, which a
loopback Docker interface can't reproduce: each received resend-request
pushes a `channel_busy_until` deadline forward, and the driver only sends
the real missing packets once that deadline passes. Prints
`RECV-REQUEST`/`RECOVERED` markers.

Used once (manually, not via a committed e2e script -- this was a one-off
verification, not a standing regression guard) to answer "does the fix
actually shorten recovery, not just reduce request count": against
unfixed code (temporarily reverted `lib/raop_buffer.c`, rebuilt, restored
after), the model doesn't converge on its own -- `RAOP_BUFFER_LENGTH`'s
256-entry cap (`lib/raop_buffer.c`) force-flushes the buffer first,
silently discarding the lost content instead of ever completing a clean
resend (253 keepalive packets at 5ms matches the observed ~1.27s almost
exactly). This lines up with the real capture too: by the end of each
real ~2.8s dropout, the buffer's backlog had grown to ~259 sequence
numbers, right at the same cap. Against the fix, the same scenario
resolves via a genuine clean resend in ~10ms on the first request. Not a
literal prediction of "2.8s" -- a model demonstrating the mechanism
(fewer redundant requests leaves the buffer nowhere near its overflow
threshold), not a physical WiFi simulation.

## `tools/test-audio-reconnect-latency-e2e.sh`: reconnect-latency regression guard

Drives plain `-threadtest N` (not a separate mode) and measures, per cycle,
`SEND-TEARDOWN` -> the next cycle's first `RENDER-BUFFER-CALL` — the full
server-side "reconnect to audio flowing again" span. Two runs: a 50-cycle
`UX_THREADTEST_GAP_S=0` stress run (hunts for a slow/growing outlier no
single real capture could show) asserted against a 0.5s threshold, and a
10-cycle `UX_THREADTEST_GAP_S=1` run reported informationally only (the
inserted 1s gap deliberately approximates the client-paced,
not-server-controllable portion of a real reconnect — see
`docs/bugs/2026-09-14-audio-resume-latency-on-seek.md` — so it's not
gated against the same threshold, just used to sanity-check that the
stress run's numbers are representative of real-world scale). An isolated
cycle producing no `RENDER-BUFFER-CALL` at all (lost synthetic UDP sync
packet, see "Known limitation" above) is tolerated up to 10% of cycles —
that's "no data", not "over threshold", and conflating the two would make
this an unreliable regression guard.
