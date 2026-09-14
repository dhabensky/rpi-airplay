# Audio pipeline: threading and state machine

Reference document for `renderers/audio_renderer.c`, `lib/raop_rtp.c`,
`lib/raop.c`, `lib/raop_handlers.h`. All facts cited to `file:line`.

## Threads that touch audio state

| Thread | Role |
|---|---|
| **httpd thread** (`httpd.c:699`, the single `select()`-based RTSP/HTTP loop — see `docs/video-pipeline.md` for the full thread table) | Runs every request handler, including the audio SETUP handler (`raop_handlers.h:1027` on), which calls `audio_get_format()` → `audio_renderer_start_deferred()` (`uxplay.cpp`) and `raop_rtp_start_audio()`, in that order, in the same function. Also runs `conn_request()` (`raop.c:190`), the per-connection-type classifier. |
| **RAOP audio thread** (`raop_rtp.c:705`, (re)created per `raop_rtp_start_audio()` call) | Runs `raop_rtp_thread_udp()` — reads incoming audio RTP, decrypts, calls `audio_process()` (→ `audio_renderer_render_buffer()`, `raop_rtp.c:631`) and, via `raop_rtp_process_events()`, `audio_set_volume`/`audio_flush` (`raop_rtp.c:314-322`). Exits when `raop_rtp->running` goes false (`raop_rtp.c:270-273`). |
| **RAOP NTP thread** (`raop_ntp.c:437`) | Clock sync only. |
| **Main thread** | Runs the `GMainLoop`; executes every `g_idle_add()`-deferred callback, including `audio_renderer_start_deferred()`/`audio_renderer_self_heal_deferred()`. |

## Two separate "audio" state machines

1. **The RTP-receiving layer** (`lib/raop_rtp.c`): a UDP socket pair +
   `raop_rtp_thread_udp()` thread, tracked by `raop_rtp->running`/`joined`,
   protected by `raop_rtp->run_mutex` within this file (every touch of
   `running`/`joined` is inside a matching `MUTEX_LOCK`/`MUTEX_UNLOCK` pair,
   `raop_rtp.c:269-309,644-857`). A SETUP request creates or reuses this
   object (`raop_rtp_start_audio()`); the same `raop_rtp_t` persists across
   every TEARDOWN+SETUP cycle on a connection — it is destroyed only when
   the connection itself is destroyed (`conn_destroy()`, `raop.c:576-586`)
   or on a genuine key-exchange "first SETUP" (`raop_handlers.h:920-926`).
   This layer only knows about encrypted RTP packets on the wire — nothing
   about GStreamer.
2. **The GStreamer rendering layer** (`renderers/audio_renderer.c`): the
   module-static `renderer` pointer + per-format pipelines, built once at
   startup and switched between by `audio_renderer_start()`. This decodes
   and plays sound. No locking in this file — pipeline-mutating calls are
   instead serialized onto the main thread (see below).

A SETUP request's handler (httpd thread, `raop_handlers.h:1027` on)
touches both, in sequence, in the same function: `audio_get_format()` →
`audio_renderer_start_deferred()` (layer 2, deferred) first, then
`raop_rtp_start_audio()` (layer 1, synchronous).

## RTP-timestamp-to-NTP-time sync state

`raop_rtp_t` holds three fields that map a packet's raw RTP timestamp to
an absolute NTP time: `rtp_sync`, `client_ntp_sync`, `initial_sync`
(`raop_rtp.c`, struct fields). `rtp_time_to_client_ntp()`
(`raop_rtp.c:359-377`) computes `ntp_time_remote` for each packet from
these; it returns `0` (meaning "not synced yet") whenever
`!initial_sync`. A periodic RTCP sync packet (type `0x54`,
`raop_rtp.c:499-520`) updates `rtp_sync`/`client_ntp_sync` and sets
`initial_sync = true`.

Because the same `raop_rtp_t` persists across restarts on a connection,
`raop_rtp_start_audio()` (`raop_rtp.c:662`) resets all three fields back
to their unsynced state (`rtp_sync = 0; client_ntp_sync = 0; initial_sync
= false;`) at the top of every (re)start, right after the redundant-SETUP
guard. This guarantees each fresh RTP-timestamp range (every SETUP
restarts the client's RTP timestamp counter) is never combined with a
sync reference point computed for a *different* timestamp range — the
result would otherwise be an arbitrary, wildly wrong absolute NTP time
until the next sync packet arrives. The redundant-SETUP guard immediately
above this reset (`raop_rtp.c:670-687`) already guarantees the previous
audio thread has fully exited and been joined before it runs, so no lock
is needed around the reset itself.

## GStreamer pipeline construction (per format)

`audio_renderer_init()` (`audio_renderer.c:131`, called once at startup,
main thread) builds one static `gst_parse_launch()` pipeline per audio
format (`NFORMATS = 2` in practice — AAC-ELD and ALAC) and keeps all of
them alive for the process lifetime in `renderer_type[]`:

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
`renderer_type[]`'s pre-built pipelines is currently active.
`audio_renderer_start()` (`audio_renderer.c:306`) has two branches when a
renderer already exists:
- **Codec change** (`*ct != renderer->ct`): sends
  `gst_app_src_end_of_stream()`, drops the old pipeline to
  `GST_STATE_NULL`, switches `renderer` to the new format's pipeline, sets
  it to `GST_STATE_PLAYING`, and refreshes `gst_audio_pipeline_base_time`.
  `gst_app_src_end_of_stream()` permanently marks that appsrc EOS'd —
  cycling pipeline state afterward does not clear it — so this sequence is
  only safe when abandoning this renderer for a different one, never when
  reusing the same one.
- **Same-codec restart** (the common case — a real AirPlay client tears
  down and re-SETUPs the *same* stream on every track switch): only
  refreshes `gst_audio_pipeline_base_time`. No EOS, no pipeline state
  cycling — the pipeline and appsrc are left exactly as they are; only the
  stale clock reference needs updating for the new session.

Both `audio_renderer_start()` and the self-heal path below are only ever
invoked via `audio_renderer_start_deferred()`/`audio_renderer_self_heal_deferred()`
(`g_idle_add()` onto the main thread) from their real call sites — never
called directly from the httpd thread or the RAOP audio thread. Every
*other* existing caller of the synchronous `audio_renderer_start()`/
`audio_renderer_stop()` is unaffected (e.g. `audio_renderer_destroy()`
still calls `audio_renderer_stop()` synchronously, since it must complete
before freeing the structures `renderer` points into).

## Self-heal path

`audio_renderer_render_buffer()` (RAOP audio thread, called once per
incoming audio packet) has a self-heal-on-failure path
(`audio_renderer.c:377-397`): if `gst_app_src_push_buffer()` returns
anything other than `GST_FLOW_OK`, it calls
`audio_renderer_self_heal_deferred()`, which runs
`audio_renderer_stop()`+`audio_renderer_start()` as one atomic pair on the
main thread (not two separate idle callbacks, which another thread could
interleave between).

## `conn_request()`'s connection-type classification

`conn_request()` (`raop.c:190`), the httpd thread's per-request
connection-type classifier: an AirPlay client can open a legacy
`CSeq`-based `RAOP` connection and/or a newer `X-Apple-Session-ID`-based
`AIRPLAY` connection. The first request on a not-yet-classified connection
runs this block (`raop.c:270-339`):

- A second same-type (`RAOP`) connection is rejected with 409 Conflict
  unless `-nohold` is set (`raop.c:270-287`).
- When an `AIRPLAY`-type connection is classified
  (`else if (client_session_id)`, `raop.c:292`) and an existing
  `RAOP`-type connection exists
  (`httpd_get_connection_by_type(..., CONNECTION_TYPE_RAOP, 1)`,
  `raop.c:308`), `raop_should_teardown_existing_connection()`
  (`lib/raop_conn_policy.c`) compares the two connections' remote
  addresses: a byte-for-byte match leaves the existing connection's
  mirror/audio/NTP services alone; any mismatch (including differing
  address length/family) tears them down, matching the original
  always-teardown behavior for a genuinely different client.

## State/protection table

| State | Type | Written from | Read from | Protection |
|---|---|---|---|---|
| `renderer` (`audio_renderer.c:56`) | raw pointer | Main thread only (via the two deferred entry points above) | RAOP audio thread (`audio_renderer_render_buffer()`, `audio_renderer_set_volume()`, `audio_renderer_flush()`) | Single-writer (main thread only) by construction; no lock needed. |
| `gst_audio_pipeline_base_time` (`audio_renderer.c:34`) | `GstClockTime` | Main thread only | RAOP audio thread (`audio_renderer_render_buffer()`'s PTS-rebase logic) | Single-writer by construction. |
| `render_audio`, `sync` (`audio_renderer.c:42,45`) | plain `gboolean` | Main thread only, inside `get_renderer_type()` (called from `audio_renderer_start()`) | RAOP audio thread (`audio_renderer_render_buffer()`'s first line gates on `render_audio`) | Single-writer by construction. |
| `raop_rtp->running`/`joined` (`raop_rtp.c`) | `int` bitflags | httpd thread (`raop_rtp_start_audio()`) and the RAOP audio thread's own exit path | Both | `run_mutex`, consistently applied within `raop_rtp.c`. |
| `raop_rtp->rtp_sync`/`client_ntp_sync`/`initial_sync` (`raop_rtp.c`) | mixed | httpd thread, at the top of `raop_rtp_start_audio()` (reset); RAOP audio thread (updated by sync packets, read by every packet) | RAOP audio thread | No lock; safe because the redundant-SETUP guard guarantees the previous audio thread has exited before the httpd thread's reset runs, and only the RAOP audio thread touches these fields afterward until the next restart. |

## What's NOT covered by this document

- `raop_rtp.c`'s own internal locking beyond what's tabulated above.
- ALSA's own internal buffering/thread-safety once `alsasink` hands data
  off to it — treated as an opaque, correctly-synchronized dependency.
- Video: see `docs/video-pipeline.md`. DRM plane/framebuffer detail: see
  `docs/framebuffers-and-drm-planes.md`.
