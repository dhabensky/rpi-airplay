# Bug: audio dies permanently after a repeated audio SETUP on the same connection

Status: **Fixed and confirmed live.**

## Symptom

Audio goes permanently silent after an AirPlay client tears down and
re-establishes the embedded audio stream on an existing mirror connection
(e.g. triggered by switching tracks or refreshing a page in a mirrored
browser tab). Video is unaffected. No errors are logged. Does not
self-recover.

## Root cause

`raop_rtp_t`'s RTP-timestamp-to-NTP-time sync state (`rtp_sync`,
`client_ntp_sync`, `initial_sync`, `lib/raop_rtp.c`) was set once, in the
one-time constructor, and never reset elsewhere. The same `raop_rtp_t`
object persists across every TEARDOWN+SETUP cycle on a connection, so a
restart's freshly-reset RTP timestamp range was combined with the
*previous* session's sync reference point, producing an absolute NTP time
computation off by an arbitrary, often very large amount until the next
periodic RTCP sync packet corrected it. That value becomes the buffer's
GStreamer PTS; once such a buffer reaches a `sync=true` ALSA sink, its
playback-position tracking does not recover — every subsequent,
correctly-timed buffer is treated as late and dropped.

## Fix

`raop_rtp_start_audio()` (`lib/raop_rtp.c`) resets `rtp_sync`,
`client_ntp_sync`, and `initial_sync` to their unsynced state at the start
of every (re)start. This makes `rtp_time_to_client_ntp()` correctly report
"not synced yet" until a genuine sync packet arrives for the new session,
which `audio_renderer_render_buffer()`'s existing re-base logic
(`renderers/audio_renderer.c`) already handles safely.

A second, independent fix in the same area: `audio_renderer_start()`
(`renderers/audio_renderer.c`) now refreshes `gst_audio_pipeline_base_time`
on every restart, including a same-codec restart (previously a no-op for
that case — see `docs/audio-pipeline.md` for the current pipeline
construction/restart behavior).

## Verification

`tools/test-audio-ntp-resync-e2e.sh`: an automated regression test against
the current working tree. It drives a scripted client (`-ntpresynccheck`,
`uxplay.cpp`) that establishes a real session and sync, restarts it, and
sends a probe packet before any new sync arrives — asserting that packet
is withheld until a fresh sync arrives and then renders with a timestamp
consistent with a later, correctly-synced probe. Runs entirely in Docker,
no live client or Pi hardware needed. `./tools/test-audio-ntp-resync-e2e.sh`
reports PASS. Separately validated once, manually (temporarily swapping
`lib/raop_rtp.c` to the pre-fix revision, never done by the script itself),
that this same check fails against the bug.

Also deployed live and observed surviving repeated real TEARDOWN+SETUP
restart cycles with no reproduction — supporting evidence, not a
substitute for the automated test above (see memory: bug_fix_protocol).

Not yet baked into a rebuilt image (the live device runs it via
SSH-deployed binary).

`tools/test-render-health-e2e.sh` and `-replay` in general cannot validate
this fix: they bypass `lib/raop_rtp.c` (the layer both the bug and the fix
are in) entirely, and captures recorded during a real occurrence of this
bug replay their originally-recorded (wrong) timestamps verbatim
regardless of which binary replays them.

Full architectural detail: `docs/audio-pipeline.md`.
