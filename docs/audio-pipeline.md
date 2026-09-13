# Audio pipeline: threading and state machine

Status: reference document, split out and substantially extended
2026-09-13 from the original combined
`video-audio-threading-and-state-machine.md` (see `docs/README.md` for
the full set). Structurally simpler than video (no DRM planes, no
overscan/hide mechanism) but with real, code-grounded hazards directly
relevant to the currently-open
`bugs/2026-09-13-audio-dies-on-repeated-track-switch-setup.md`
investigation — including a major finding from comparing against pristine
upstream (see "The `conn_request()` finding" below), found *after* the
first version of this document already existed, while preparing
`docs/upstream-comparison.md`.

All facts cited to `file:line`; `renderers/audio_renderer.c` (482 lines)
and `lib/raop_rtp.c`/`lib/raop.c`/`lib/raop_handlers.h` were read in full,
not sampled.

## Threads that touch audio state

| Thread | Role |
|---|---|
| **httpd thread** (`httpd.c:699`, the single `select()`-based RTSP/HTTP loop — see `docs/video-pipeline.md` for the full thread table) | Runs **every** request handler, including the audio SETUP handler (`raop_handlers.h:1027` on), which calls `audio_get_format()` → `audio_renderer_start()` (`uxplay.cpp:2851`) *and* `raop_rtp_start_audio()`, in that order, in the same function. Also runs `conn_request()` (`raop.c:190`), which — for reasons detailed below — can unilaterally kill an already-running audio session. |
| **RAOP audio thread** (`raop_rtp.c:705`, (re)created per `raop_rtp_start_audio()` call) | Runs `raop_rtp_thread_udp()` — reads incoming audio RTP, decrypts, calls `audio_process()` (→ `audio_renderer_render_buffer()`, `raop_rtp.c:631`) and, via `raop_rtp_process_events()`, `audio_set_volume`/`audio_flush` (`raop_rtp.c:314-322`). Owns essentially all per-buffer audio rendering calls except `audio_renderer_start()` itself. Exits when `raop_rtp->running` goes false (`raop_rtp.c:270-273`). |
| **RAOP NTP thread** (`raop_ntp.c:437`) | Clock sync only; not directly relevant to audio rendering state, but torn down by the same `conn_request()` path as audio (see below). |

## Two separate "audio" state machines, easy to conflate

This codebase actually has **two independent audio lifecycles**, owned by
different files and different threads, that only interact indirectly:

1. **The RTP-receiving layer** (`lib/raop_rtp.c`): a UDP socket pair +
   `raop_rtp_thread_udp()` thread, tracked by `raop_rtp->running`/`joined`,
   both properly protected by `raop_rtp->run_mutex` **within this file**
   (verified directly: every touch of `running`/`joined` is inside a
   matching `MUTEX_LOCK`/`MUTEX_UNLOCK` pair, `raop_rtp.c:269-309,644-857`).
   This is what a SETUP request creates or reuses (`raop_rtp_start_audio()`).
   It only knows about encrypted RTP packets on the wire — nothing about
   GStreamer.
2. **The GStreamer rendering layer** (`renderers/audio_renderer.c`): the
   module-static `renderer` pointer + per-format pipelines, built once at
   startup and switched between by `audio_renderer_start()`. This is what
   actually decodes and plays sound. **No locking anywhere in this file.**

A SETUP request's handler (httpd thread, `raop_handlers.h:1027` on)
touches **both**, in sequence, in the same function: `audio_get_format()`
(→ `audio_renderer_start()`, layer 2) first, then `raop_rtp_start_audio()`
(layer 1). They are two separate calls with no shared lock between them,
into two separately-synchronized (or unsynchronized) subsystems.

## GStreamer pipeline construction (per format)

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
untouched by a same-format redundant SETUP.

## State/protection table

| State | Type | Written from | Read from | Protection |
|---|---|---|---|---|
| `renderer` (`audio_renderer.c:56`) | raw pointer | httpd thread (`audio_renderer_start()`) **and** RAOP audio thread (`audio_renderer_render_buffer()`'s self-heal path, see below, calls `audio_renderer_stop()`+`audio_renderer_start()` again) | RAOP audio thread (`audio_renderer_render_buffer()`, `audio_renderer_set_volume()`, `audio_renderer_flush()`) | **None.** Unlike video's `renderer` (written by exactly one non-main thread, see `docs/video-pipeline.md`), audio's `renderer` can be written by **two different threads** — httpd thread on every SETUP, RAOP audio thread on every self-heal — with no lock, no atomic, nothing. |
| `gst_audio_pipeline_base_time` (`audio_renderer.c:34`) | `GstClockTime` | Same two threads, same two call sites | RAOP audio thread (`audio_renderer_render_buffer()`'s PTS-rebase logic, `audio_renderer.c:322-333`) | **None.** |
| `render_audio`, `sync` (`audio_renderer.c:42,45`) | plain `gboolean` | httpd thread, inside `get_renderer_type()` (`audio_renderer.c:257`, called from `audio_renderer_start()`) | RAOP audio thread (`audio_renderer_render_buffer()`'s very first line gates on `render_audio`) | **None.** |
| `raop_rtp->running`/`joined` (`raop_rtp.c`) | `int` bitflags | httpd thread (`raop_rtp_start_audio()`) and the RAOP audio thread's own exit path (`raop_rtp_thread_udp`) | Both | **Real** — `run_mutex`, consistently applied within `raop_rtp.c` (see above). Does not extend to `audio_renderer.c`. |

## The `conn_request()` finding

While preparing `docs/upstream-comparison.md` (diff against pristine
upstream tag `v1.73.7` = submodule commit `df67c21`), a comment already
left in this codebase by an *earlier* session (`raop.c:310-314`, added in
submodule commit `268e168`, 2026-09-11) turned out to describe this exact
bug class, unresolved at the time it was written:

```c
raop_rtp_t *raop_rtp = raop_conn->raop_rtp;
if (raop_rtp) {
    logger_log(raop->logger, LOGGER_INFO, "New AirPlay connection: stopping RAOP audio"
               " service on RAOP connection %p (this closes the just-negotiated audio"
               " UDP sockets -- if this fires right after an AUDIO SETUP response, the"
               " client was told a port that's already been torn down by the time it"
               " sends anything there)", raop_conn);
    raop_rtp_stop(raop_rtp);
}
```

This is inside `conn_request()` (`raop.c:190`), the httpd thread's
per-request connection-type classifier. Per the function's own header
comment, an AirPlay client can open **two different connection types**:
a legacy `CSeq`-based `RAOP` connection and a newer
`X-Apple-Session-ID`-based `AIRPLAY` connection. The very first request on
a not-yet-classified connection runs this block (`raop.c:270-332`):

- If it's an `AIRPLAY`-type request (`else if (client_session_id)`,
  `raop.c:291`) and an existing `RAOP`-type connection is found
  (`httpd_get_connection_by_type(..., CONNECTION_TYPE_RAOP, 1)`,
  `raop.c:299`), it **unconditionally** stops that connection's mirror,
  audio, and NTP services (`raop.c:301-323`) — comment: *"airplay video
  has been requested: shut down any running RAOP udp services"*.
- This is a **different** code path from the `-nohold`/409-Conflict logic
  a few lines above (`raop.c:270-287`), which only fires for a second
  *same-type* (`RAOP`) connection and is disabled by default (memory: bug
  #1, `-nohold` was tried and reverted).

**Why this plausibly explains bug #10's exact signature**: if switching a
YouTube tab's track causes the client to open a fresh `AIRPLAY`-type
connection (as opposed to reusing the existing session), this code tears
down the *audio* UDP sockets on the still-active `RAOP` connection
unconditionally — with no check for whether that audio session is still
wanted, still in use, or was negotiated moments ago. If this fires
**immediately after** an `AUDIO SETUP response` already told the client a
port to use, that port is dead before the client ever sends anything to
it — exactly the comment's own prediction, and exactly consistent with
every observed reproduction: audio permanently silent, no error, video
unaffected (video's `RAOP` mirror connection either isn't the one torn
down, or recovers via the `HIDDEN`/`choose_codec()` restore mechanism in
`docs/video-pipeline.md` — audio has no equivalent restore path).

This is **more explanatory than the self-heal race below**: the existing
self-heal in `audio_renderer_render_buffer()` (next section) only fires
when `gst_app_src_push_buffer()` actually gets called and fails — but if
the client's audio RTP packets never arrive at all (because it was told a
now-dead port), `audio_renderer_render_buffer()` is never even invoked
post-teardown, so there is nothing to self-heal from. This matches the
2026-09-11 commit's own words describing the *pre-self-heal* failure mode
almost verbatim: *"audio would just stop forever, with zero log trace,
recoverable only by the client tearing down and re-establishing the whole
AirPlay session from scratch"* — i.e. this specific gap was never actually
fixed by that session, only diagnosed and left as a comment.

**Not yet confirmed**: whether track-switching genuinely opens a new
`AIRPLAY`-type connection (vs. some other trigger for the observed
`raop_rtp starting audio` bursts) — needs the same clean debug capture
already named in the bug's "Next diagnostic step" section, ideally with
`LOGGER_DEBUG` connection-type classification logging enabled
(`raop.c:288,292,326` are all `LOGGER_DEBUG`, invisible at the production
`LOGGER_INFO` level).

## A second, independent hazard: the self-heal race

`audio_renderer_render_buffer()` (RAOP audio thread, called once per
incoming audio packet) has its own **self-heal-on-failure** path
(`audio_renderer.c:377-397`, added in a prior session specifically because
this failure used to be completely silent — see its own comment): if
`gst_app_src_push_buffer()` returns anything other than `GST_FLOW_OK`, it
calls `audio_renderer_stop()` then `audio_renderer_start()` **itself, from
the RAOP audio thread** — touching exactly the same `renderer` pointer and
the exact same GStreamer pipeline state transitions
(`gst_app_src_end_of_stream`, `gst_element_set_state`) that the **httpd
thread** can be doing at the same moment for a concurrently-arriving SETUP
request.

Neither call site takes any lock. This is a real, independent hazard from
the `conn_request()` finding above — plausible as a *secondary*
contributor (e.g. if a burst of rapid connections/SETUPs disrupts timing
enough to trip this self-heal concurrently with the httpd thread's own
`audio_renderer_start()` call) but doesn't by itself explain why the
*existing* self-heal mechanism fails to recover audio in bug #10's
reproductions — the `conn_request()` finding above does.

## What's NOT covered by this document

- `raop_rtp.c`'s own internal locking is real and correctly used *within*
  that file (verified above); only the *cross-file* gap (nothing in
  `audio_renderer.c` or the httpd-thread call path takes any lock at all)
  is in scope here.
- ALSA's own internal buffering/thread-safety once `alsasink` hands data
  off to it — treated as an opaque, correctly-synchronized dependency.
- `conn_request()`'s handling of the `RAOP` mirror and NTP teardown calls
  (`raop.c:301-309,318-323`) — same unconditional-teardown shape as audio,
  not separately traced here since video's own `HIDDEN`/restore mechanism
  already covers "mirror connection torn down and re-established"
  gracefully (`docs/video-pipeline.md`); NTP teardown's downstream effects
  not investigated.
- Video: see `docs/video-pipeline.md`. DRM plane/framebuffer detail: see
  `docs/framebuffers-and-drm-planes.md`.
