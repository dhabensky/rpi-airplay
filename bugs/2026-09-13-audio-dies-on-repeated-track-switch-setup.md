# Bug: audio dies permanently after a burst of repeated SETUP requests (YouTube track-switching)

Status: **confirmed reproducible, long-standing; strongest root-cause
hypothesis found (section 5) via upstream comparison; fix proposed
(section 6), not yet implemented — awaiting review**

## 1. Description (as reported and directly reproduced)

Reported: 2026-09-13, on the freshly reflashed, regression-tested,
reverted baseline (see `bugs/2026-09-13-audio-resume-latency-after-
teardown.md` for that revert).

- Trigger: switching tracks on YouTube (in a browser tab) while
  AirPlay-mirroring that tab. Not tied to a specific number of switches —
  reproduced with a burst of 4 and separately a burst of 7 rapid `SETUP`
  requests.
- **Confirmed long-standing, not a regression**: the user has seen this
  before tonight's session, on older builds.
- Symptom: audio goes completely and permanently silent. **Video is
  unaffected** — confirmed via `tools/drmdump.c` polling plane 98's
  `fb_id` during a live reproduction: it kept changing (677 -> 675 -> 673
  across three 2s-spaced polls), i.e. genuinely still rendering new
  frames, while audio stayed dead.
- Does **not** self-recover. Confirmed twice: after the SETUP burst stops
  appearing in the log, audio remains silent indefinitely (checked
  immediately after and again ~30s later in one reproduction).

## 2. Reproduced cleanly, independent of tonight's other work

This was directly reproduced **twice** against the fully-reverted
baseline (submodule `d2731a6`, content-identical to `7402efa` --
confirmed via empty diff, see the audio-resume-latency bug doc) running
as the **normal, unmodified production `uxplay.service`** (no `-d`, no
manual restart, no debug flags) -- ruling out any involvement from
tonight's frozen-frame-hide feature or its revert. This is not something
to bisect against a recent commit; it predates every change made this
session.

(An earlier reproduction attempt tonight was contaminated by the
investigator manually restarting the service mid-session to enable debug
logging, which the user correctly flagged as not representative -- that
attempt is discarded from evidence; both reproductions counted above are
against the clean, untouched production service.)

## 3. What's confirmed vs. still unknown

**Confirmed** (from the plain `LOGGER_INFO`-level production log, both
reproductions):
```
ct=8 spf=480 usingScreen=1 isMedia=1  audioFormat=0x1000000
raop_rtp starting audio
raop_rtp local control port socket 46 port UDP <fresh port>
raop_rtp local data port    socket 48 port UDP <fresh port>
AUDIO SETUP response: dataPort=<fresh> controlPort=<fresh> remote_cport=<fresh> ct=8 sr=44100
```
repeating 4-7 times in quick succession, **each with a brand new port
pair**, then nothing further logged. The ALSA PCM device
(`/dev/snd/pcmC0D0p`) stays held open by the main process throughout
(`fuser` confirmed this during the first reproduction).

**Traced in the source** (`lib/raop_rtp.c`), not yet confirmed against
which branch actually executes live:
- `raop_rtp_start_audio()` (`raop_rtp.c:655` on) has a redundant-SETUP
  guard: `if (raop_rtp->running || !raop_rtp->joined) { ...return cached
  ports... }` (`raop_rtp.c:664`). A **fresh port every time**, as
  observed, means this guard is *not* firing on any of these calls --
  each one is taking the real thread-creation path.
- The only two places that touch `raop_rtp->joined`: initialized to `1`
  in `raop_rtp_new()` (`raop_rtp.c:177`); set back to `1` only inside
  `raop_rtp_stop()` (`raop_rtp.c:847`), which itself refuses to run at all
  if `!raop_rtp->running` (`raop_rtp.c:823`) -- i.e. **a thread that has
  already exited on its own is never joined or marked joined by anything
  in this file.** Whether that's what's actually happening here (vs. a
  real `TEARDOWN(96)` arriving before each SETUP and legitimately calling
  `raop_rtp_stop()` while the thread is still alive, which would also
  explain a fresh port each time without being a bug) is **not yet
  determined** -- both would produce the exact same fresh-port-every-time
  log signature at `LOGGER_INFO` level; distinguishing them needs
  `-d`/`LOGGER_DEBUG` output (which logs `"TEARDOWN request, 96=.., 110=.."`,
  `raop_rtp.c` / `raop_handlers.h`) captured against a *clean*
  reproduction -- the one debug capture attempted tonight was against a
  freshly-restarted process and is not trustworthy for this (see section
  2's caveat).
- Elevated thread count observed on the process during the first live
  reproduction (14 threads for a process that should have on the order of
  5-8) -- noted as a possible lead (thread accumulation if threads really
  are going unjoined) but **not yet confirmed** as related rather than
  coincidental; not re-checked on the second, cleaner reproduction.
- This general area (`raop_rtp_start_audio()`'s redundant-SETUP handling)
  is already flagged as a known risk in
  `docs/audio-pipeline.md`, item 2 --
  written before this specific bug was reproduced live, from reading the
  code alone.

**Not yet known**: whether real audio RTP *data* packets ever arrive at
the last-opened port at all (client-side silently giving up vs.
server-side silently failing to process what does arrive), whether the
thread count genuinely grows unboundedly across repeated occurrences, and
whether a real `TEARDOWN(96)` request precedes each of these SETUPs.

**Second, more concrete hypothesis found while documenting the audio
pipeline** (`docs/audio-pipeline.md`):
`audio_renderer_start()` (httpd thread, called inline from the SETUP
handler, `audio_renderer.c:293`) and `audio_renderer_render_buffer()`'s
own self-heal-on-push-failure path (`audio_renderer.c:377-397`, RAOP audio
thread, triggers on any non-`GST_FLOW_OK` from `gst_app_src_push_buffer()`)
both write the *same* unlocked `renderer` pointer and perform the same
`gst_app_src_end_of_stream`/`gst_element_set_state` calls on it, with zero
locking between them -- unlike `lib/raop_rtp.c`'s own `running`/`joined`
fields, which ARE consistently mutex-protected within that file (checked,
not assumed). A burst of rapid SETUPs disrupting timing enough to trip the
audio thread's self-heal condition, concurrently with the httpd thread's
own `audio_renderer_start()` call for the next SETUP, would explain a
permanently-dead `renderer`/pipeline without needing the `raop_rtp.c`-layer
`joined` question above to be the cause at all. Both hypotheses need the
same next step (a clean debug capture) to distinguish.

## 4. Next diagnostic step (not yet done)

A clean `-d`/full-debug capture is needed, taken **without restarting the
service mid-reproduction** this time (that's what made the first attempt
tonight non-representative) -- e.g. enable debug logging in the
`uxplay.service` unit itself (or accept losing the very first few seconds
of an already-fresh session) rather than stopping and manually restarting
a session the user is actively using. This should distinguish the two
live hypotheses above (thread never joined vs. legitimate repeated
teardown+setup) before any fix is designed. **Still worth doing** to
positively confirm section 5 below before shipping the fix, even though
section 5 no longer needs it to be *proposed*.

## 5. Strongest hypothesis (found via upstream comparison): `conn_request()`

While preparing `docs/upstream-comparison.md`, found that a prior session
(submodule `268e168`, 2026-09-11) already left a comment in
`lib/raop.c:310-314` describing this exact failure mode, never actually
fixed -- see `docs/audio-pipeline.md`'s "The `conn_request()` finding"
section for the full trace. Summary: `conn_request()` (httpd thread),
when classifying a new `AIRPLAY`-type connection (`X-Apple-Session-ID`
header present), **unconditionally** tears down an existing `RAOP`-type
connection's audio/mirror/NTP services if one exists
(`raop.c:298-324`) -- with no check for whether that's a genuinely
different client or the same client's own auxiliary connection. This is
**upstream's own original behavior**, byte-identical to pristine
`v1.73.7` -- not something either fork introduced.

This explains the observed signature better than either hypothesis in
section 3: if switching tracks causes the client to open a fresh
`AIRPLAY`-type connection, this code kills the just-negotiated audio UDP
socket on the *other* connection -- exactly the scenario the 2026-09-11
comment itself predicted ("if this fires right after an AUDIO SETUP
response, the client was told a port that's already been torn down by
the time it sends anything there"). It also explains why the *existing*
self-heal in `audio_renderer_render_buffer()` (section 3's second
hypothesis) never kicks in: that only fires when a push is attempted and
fails; if the client's packets never arrive at all because it was told a
dead port, there's nothing to self-heal from.

## 6. Fix Plan

Two independent, narrowly-scoped fixes -- not a rewrite:

**Fix A (primary, addresses section 5):** don't tear down an existing
`RAOP` connection's audio/mirror/NTP services in `conn_request()` when
the new `AIRPLAY`-type connection is plausibly the *same* client's own
auxiliary connection. Extract the decision into a small, pure,
independently-testable helper:

```c
/* Returns true if the existing RAOP connection's audio/mirror/NTP
 * services should be torn down because the new AIRPLAY-type connection
 * represents a genuinely different client; false if it's plausibly the
 * same client's own auxiliary connection (e.g. opened when switching
 * tracks within an ongoing mirror session) and the existing session
 * should be left alone. */
bool raop_should_teardown_existing_connection(const char *existing_remote_ip,
                                               const char *new_remote_ip);
```

Implementation: compare `existing_remote_ip`/`new_remote_ip` (both already
available at the call site via `utils_ipaddress_to_string()`, the same
helper the neighboring `-nohold` branch already uses a few lines above,
`raop.c:273-274`) -- different IP means teardown (preserves upstream's
actual intent: a genuinely new client should preempt), same IP means skip
it. `conn_request()` calls this before `raop.c:301-323`'s teardown block
instead of running it unconditionally.

**Known limitation, to confirm via section 4's diagnostic capture**: IPv6
privacy-extension address rotation could in principle defeat an IP-based
match. Believed low-risk for this specific scenario (LAN-local
mDNS-discovered AirPlay traffic typically uses a stable interface
address, not a WAN-facing privacy address), but not proven -- if the
diagnostic capture shows the two connections arrive from *different*
remote addresses despite being the same physical client, this heuristic
needs a different correlator (e.g. stashing whatever client-identifying
data becomes available once parsed, such as the `deviceID` seen in
pairing-related plist bodies, `raop_handlers.h:642-643` -- not available
at `conn_request()`'s point in the request lifecycle today without
additional plumbing).

**Fix B (secondary, addresses the section 3 cross-thread hazard
independent of whether Fix A alone resolves the bug):** serialize
`audio_renderer.c`'s pipeline-mutating calls (`audio_renderer_start()`,
and the self-heal path's `audio_renderer_stop()`+`audio_renderer_start()`
pair) onto a single thread via `g_idle_add()`, the same
already-established pattern this project uses elsewhere (the overscan
`GFileMonitor` callback). Concretely: the httpd thread's call to
`audio_renderer_start()` and the RAOP audio thread's self-heal call both
become "post a request to run on the main thread's `GMainLoop`" instead
of calling directly -- matching the architecture direction the user
prefers (fewer threads touching shared pipeline state, not a better test
harness papering over more of them). Low risk: these calls are already
infrequent (once per SETUP, or rarely on a genuine push failure), so
deferring them by one main-loop iteration has no perceptible latency
cost, unlike the mistake made with `video_renderer_hide_video()` earlier
tonight (which deferred a *visible-effect* call, not applicable here).

Fix A is expected to resolve the bug on its own if section 5's hypothesis
is confirmed; Fix B closes a real, independently-identified gap
regardless, and is cheap enough to include either way.

## 7. Verification Plan

**Existing regression suite** (must still pass, no behavior change
expected for the normal single-connection case):
`tools/test-reconnect-e2e.sh`, `tools/test-render-health-e2e.sh`.

**New test needed for Fix A -- `-replay` cannot cover this.**
`-replay` calls `video_process`/`audio_process`/`video_reset` directly,
entirely bypassing `raop.c`/`httpd.c` -- structurally incapable of
exercising `conn_request()`'s connection-type classification, since that
requires real RTSP-level requests over real sockets (see
`docs/upstream-comparison.md`'s `uxplay.cpp` section on what `-replay`
does and doesn't cover). Two options, not mutually exclusive:

1. **Pure unit test (recommended first step, fully autonomous, no
   hardware/network/crypto needed)**: extract
   `raop_should_teardown_existing_connection()` (Fix A) as a small,
   dependency-free pure function and test it directly, following the
   exact pattern this project already has but never wired into any
   runner -- `tests/test_bus_callback_null_renderer.c` (`#include`s the
   target `.c` file directly, stubs `logger_log`, asserts behavior).
   **Found while designing this**: that existing test isn't referenced
   from any `CMakeLists.txt`, Makefile, or script anywhere in either repo
   -- it's never actually been run automatically since it was added.
   Fixing that (a small `tests/CMakeLists.txt` or a
   `tools/run-unit-tests.sh`, compiling and running every `tests/*.c`) is
   itself a worthwhile, low-risk test-framework extension, and would
   finally exercise the existing test too.
2. **Higher-fidelity end-to-end test (optional, higher effort)**: a real
   RTSP client simulator opening a genuine second connection against the
   real server. Deliberately not proposed as a requirement here: AirPlay's
   real handshake involves `fairplay_setup`/`fairplay_handshake`
   (`raop_handlers.h:562,574`) and AES key exchange before a SETUP is
   normally reachable, so a faithful simulator is meaningfully more work
   than option 1 for the same confidence in the specific logic being
   fixed. Worth reconsidering only if option 1 can't be made to cover the
   real risk (e.g. if the actual bug turns out to depend on exact protocol
   timing option 1 can't represent).

**Manual confirmation** (real client, real network): repeat the original
YouTube track-switch reproduction, confirm audio survives at the
`-reset N` timescale expected, not permanently. Per this project's
standing rule, this closes the loop but doesn't substitute for the
automated checks above -- `-replay`/unit tests must pass first.

## Fixed in

*(not yet fixed -- fix proposed above, not yet implemented or reviewed)*
