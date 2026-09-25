# `synthetic-client`: real multi-threaded server test tool

Reference document for `UxPlay/tools/synthetic-client.cpp`, checked against
submodule commit `08abb3c`. (The filename is `threadtest.md` for historical
reasons — `threadtest` is one of nine modes, all listed below.)

`synthetic-client <mode> --port <raop_port>` drives the real
`raop_init()`/`raop_start_httpd()` server over loopback with a minimal
synthetic AirPlay client, instead of `-replay`'s single-thread
callback-injection model. This exercises the real httpd thread, real
`conn_request()`/`raop_handler_setup()` dispatch, and a real per-connection
`raop_rtp_thread_udp` — none of which `-replay` ever touches (`-replay`
calls `video_process()`/`audio_process()`/`audio_renderer_start()`
directly from one feeder thread, bypassing `lib/httpd.c` and `lib/raop.c`
entirely). Per `docs/verification-protocol.md`, that is why acceptance for
a pipeline change needs `mirrortest` plus a real run on the Pi, not
`-replay`.

## Modes

`print_usage()` in `tools/synthetic-client.cpp` is the authoritative list;
each mode is dispatched from `main()` by name to a `mode_<name>()`
function.

| Mode | Purpose | Documented in |
|---|---|---|
| `threadtest [N] [--gap-s S]` | N audio SETUP/audio/TEARDOWN cycles | this file, below |
| `mirrortest [N] [...]` | N **mirror** (video) SETUP/frames/TEARDOWN cycles, sourcing real SPS/PPS + frames from a `.cap` fixture | `docs/testing.md` |
| `ntpresync` | NTP-sync-reset-on-restart regression check | this file, below |
| `resendstorm` | resend-request-rate regression check | this file, below |
| `resendrecovery` | end-to-end resend recovery-time model | this file, below |
| `peekstall` | `httpd.c` head-of-line-blocking regression check | `mode_peekstall()` |
| `shorturl` | `httpd.c` peek-truncation / protocol-corruption check | `mode_shorturl()` |
| `shorturlfrag [N]` | `httpd.c` peek-continuation-path corruption check | `mode_shorturlfrag()` |
| `shorturlsweep <split> [N]` | splits `"GET / RTSP/1.0..."` at `<split>` bytes and prints the raw response | `mode_shorturlsweep()` |

Only `threadtest` and `mirrortest` take a positional cycle count (the
parser gates that on the mode name). `--frames-cap`,
`--frames-per-cycle`, `--abort-mirror`, `--no-teardown` and `--idle-s` are
accepted by the parser for any mode but only `mode_mirrortest()` reads
them.

## A separate process, not an in-uxplay harness

`synthetic-client` is a **standalone binary**, built alongside
`uxplay_debug` from the same CMake project (`tools/build-uxplay.sh`
builds and copies out both) but run as a genuinely separate OS process --
not a thread compiled into `uxplay.cpp` itself. The server under test is
always the real, unmodified shipped binary; zero test-only CLI flags
exist in it for this purpose. See `tools/pytest/conftest.py`'s
`TwoProcessRunner` for the exact two-process pattern the pytest suite
uses to drive this.

## `synthetic-client threadtest`: audio session lifecycle

```
# terminal/process 1: an unmodified server, audio-only, no avahi needed
uxplay -vs 0 -nohold -ble /tmp/beacon.dat -p 7000

# terminal/process 2 (or `docker exec` into the same container): the client
synthetic-client threadtest N --port <raop_port> [--gap-s S] [--host 127.0.0.1]
```

- `-vs 0` disables video, so this runs without Raspberry Pi hardware (no
  DRM/v4l2h264dec needed) — audio-only, works in a plain Docker container
  or on the Pi.
- `-ble <file>` is a real, pre-existing, non-test product flag (BluetoothLE
  beacon discovery) whose failure-tolerance path happens to let the server
  start in a plain container with no avahi/dbus daemon (`dnssd_register_raop`
  failing is otherwise fatal) -- its `write_bledata()` side effect also
  prints the real bound RAOP port (`port %u`), which is how the client
  discovers `<raop_port>` instead of reading a same-process global.
- `N` is the number of SETUP/TEARDOWN cycles to run.
- `--gap-s S`: inter-cycle gap. The client sends a `POST /feedback`
  keepalive at least every 2s during the gap, so gaps longer than the
  server's missed-feedback/`-reset` timeout (`MISSED_FEEDBACK_LIMIT`, 15s
  by default; `uxplay.service` passes `-reset 60`) don't get the connection
  killed.
- `UX_THREADTEST_DIAG=1` (env var, set on the **server** process): enables
  timing/state print lines from the server side (`TT_DIAG` macro,
  `renderers/audio_renderer.c`) — connection restart timing,
  deferred-callback execution timing, and a decode-buffer-count probe on
  the audio decoder's output pad. Harmless to leave on always; gates
  diagnostic output only, never changes server behavior.

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
   frame, `kRealAacEldFrame`) to `dataPort`, then sends TEARDOWN.
5. `controlPort` is always `0` in the SETUP **request** (the client's own
   declared port, distinct from the server's `controlPort` in the
   response used for the sync packet above): a non-zero value there
   activates `raop_buffer_dequeue()`'s resend-wait path
   (`raop_buffer_dequeue()`'s `no_resend` branch, `lib/raop_buffer.c`),
   which withholds every packet awaiting a
   genuine RTCP resend the driver never sends or answers.
6. Prints `SEND-SETUP`/`RECV-SETUP-response`/`SENT-SYNC`/
   `FIRST-AUDIO-PACKET`/`SEND-TEARDOWN`/`RECV-TEARDOWN-response`, each with
   a `now_s()` timestamp and cycle number — used by
   `tools/pytest/test_reconnect_latency.py` (see below) to measure
   reconnect latency precisely.

## Known limitation

The client sends one real captured AAC-ELD frame repeated (only
seqnum/timestamp incrementing) rather than a genuine continuous encoded
sequence. Confirmed empirically (2026-09-14, driving `threadtest` with a
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
`tools/pytest/test_reconnect_latency.py` uses it for exactly this
reason. Diagnosing genuine decode failures needs a longer/varied real
captured sequence fed frame-by-frame instead.

## `synthetic-client ntpresync`: differential regression check

```
synthetic-client ntpresync --port <raop_port>
```

A second, narrower scripted-client mode (same connection/FairPlay/SETUP
machinery as `threadtest`, different sequence): establishes a session and
a real RTCP sync packet, restarts (TEARDOWN+SETUP), sends one audio packet
*before* any new sync packet, then sends a fresh sync packet and a second
audio packet. Prints `SENT-PROBE-A`/`SENT-SYNC-2`/`SENT-PROBE-B` markers
and relies on `RENDER-BUFFER-CALL` (`renderers/audio_renderer.c`,
`UX_THREADTEST_DIAG`) for the rest. Runs to completion and exits on its
own (no long-lived server loop). Driven by
`tools/pytest/test_ntp_resync.py`, which builds the current working
tree and asserts the RTP-timestamp-to-NTP-time sync state reset in
`raop_rtp_start_audio()` behaves correctly (see `docs/audio-pipeline.md`).

## `synthetic-client resendstorm`: real ~2.8s dropout regression check

```
synthetic-client resendstorm --port <raop_port>
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
to anyone), then keeps sending one packet every ~10.9ms (AAC-ELD's real
cadence, spf=480 @ 44100Hz — **matters, not just for realism**: an
earlier version used an arbitrary faster 5ms interval, which made
`raop_buffer_dequeue()`'s 256-entry capacity threshold get reached in
~1.27s instead of the real ~2.79s the actual cadence produces, under-
predicting a real capture's observed dropout by ~2x) for 3.5s while
tracking every resend-request packet (8 bytes, `packet[1] == 0xD5`)
arriving back on its own socket. Prints two markers:
- `RESEND-REQUEST-COUNT <n> (in 3.5s, sent <n> keepalive packets)` — how
  much redundant control-channel traffic the request-rate-limit fix
  avoids. Secondary signal.
- `RESOLVED-AT <seconds>` — timestamp of the *last* resend-request
  received, i.e. how long until the server stops asking (either a genuine
  resend succeeded, or the stall-timeout force-skip gave up on it). **This
  is the real recovery-time metric** — confirmed the hard way: the
  request-rate-limit fix alone cut `RESEND-REQUEST-COUNT` ~30x on a real
  capture with zero change to `RESOLVED-AT`'s real-world equivalent (the
  actual ~2.8s dropout persisted after deploying that fix alone).

Runs to completion and exits on its own. Driven by
`tools/pytest/test_resend_storm.py`, which builds the current working
tree and asserts both `RESOLVED-AT` (primary) and the count (secondary)
stay under threshold — see
`docs/bugs/2026-09-14-audio-resume-latency-on-seek.md`.

## `synthetic-client resendrecovery`: end-to-end recovery-time comparison (no Pi/network needed)

```
synthetic-client resendrecovery --port <raop_port>
```

Same setup as `resendstorm` (real `controlPort`, permanent 5-7 gap) but a
deliberately faster 5ms keepalive stream, not `resendstorm`'s real
`480.0/44100.0` cadence — this mode measures whether a gap resolves at all,
not how long the real-world stall lasts. It also actually answers resend
requests --
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

**Correction (found after deploying and getting a real "no effect"
report)**: the buffer-capacity mechanism this model correctly identified
turned out to be the real bottleneck -- but the conclusion drawn here at
the time ("the fix" = the resend-request rate limit) was wrong. A real
capture with the rate-limit fix deployed alone showed request volume down
~30x with the actual ~2.8s dropout completely unchanged: fewer requests
never made the *client's own audio stream* (which drives how fast the
buffer's `last_seqnum` climbs, independent of how often the server asks
for a resend) arrive any faster. The real fix is the stall-timeout
force-skip in `raop_buffer_dequeue()` (`RAOP_STALL_TIMEOUT_NS`) -- see
the "Resend requests and the stall-timeout force-skip" section of
`docs/audio-pipeline.md` and `docs/bugs/2026-09-14-audio-resume-latency-on-seek.md`.
This section is kept as-is (not rewritten) as an honest record of the
investigation path, including the wrong turn.

## `tools/pytest/test_reconnect_latency.py`: reconnect-latency regression guard

Drives plain `synthetic-client threadtest N` (not a separate mode) and measures, per cycle,
`SEND-TEARDOWN` -> the next cycle's first `RENDER-BUFFER-CALL` — the full
server-side "reconnect to audio flowing again" span. Two runs: a 50-cycle
`--gap-s 0` stress run (hunts for a slow/growing outlier no
single real capture could show) asserted against a 0.5s threshold, and a
10-cycle `--gap-s 1` run reported informationally only (the
inserted 1s gap deliberately approximates the client-paced,
not-server-controllable portion of a real reconnect — see
`docs/bugs/2026-09-14-audio-resume-latency-on-seek.md` — so it's not
gated against the same threshold, just used to sanity-check that the
stress run's numbers are representative of real-world scale). An isolated
cycle producing no `RENDER-BUFFER-CALL` at all (lost synthetic UDP sync
packet, see "Known limitation" above) is tolerated up to 10% of cycles —
that's "no data", not "over threshold", and conflating the two would make
this an unreliable regression guard.
