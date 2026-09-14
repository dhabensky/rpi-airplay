# Test framework overview

What each test type actually checks, what it needs to run, and — critically
— what it does *not* check. Read the last column before trusting a "PASS".

## Unit tests — `make unit-tests`

Requires: Docker only. No hardware, no network, no Pi.

`Dockerfile.unit-tests` builds and runs each `UxPlay/tests/*.c` file as a
`RUN` step (a non-zero exit/assert failure fails the `docker build`):

| Test | Checks |
|---|---|
| `test_raop_conn_policy.c` | `raop_should_teardown_existing_connection()` (`lib/raop_conn_policy.c`) in complete isolation — no GStreamer, no mocking. |
| `test_bus_callback_null_renderer.c` | `gstreamer_audio_pipeline_bus_callback()` survives a `GST_MESSAGE_ERROR` when the file-static `renderer` is `NULL` — links `renderers/audio_renderer.c` directly. |

Scope: pure-function/single-callback correctness. Cannot exercise
threading, timing, or anything that needs a running GStreamer pipeline or
real network I/O.

## `-threadtest N` / `-ntpresynccheck` — synthetic-client, real-server tests

Requires: Docker (`make uxplay`) to build; runs via `docker run
uxplay-buildtest /usr/local/bin/uxplay -vs 0 -threadtest N` (or
`-ntpresynccheck`). No Pi hardware needed for the audio path (`-vs 0`
skips video/DRM entirely). Can also run on the Pi for a real `alsasink`
instead of `autoaudiosink`.

A minimal synthetic AirPlay client (built into `uxplay.cpp`, see
`docs/threadtest.md`) drives the *real* `raop_init()`/httpd thread/
`conn_request()`/`raop_handler_setup()`/`raop_rtp_thread_udp` over
loopback — the only way to exercise that layer without a live AirPlay
client, since `-replay` bypasses it entirely (see below).

| Mode | Checks |
|---|---|
| `-threadtest N` | Connection/session lifecycle across N real SETUP/TEARDOWN cycles (rapid or `UX_THREADTEST_GAP_S`-spaced): no orphaned `raop_rtp_t` objects, deferred-callback timing, decode-buffer counts. Exploratory/manual — prints diagnostics, no automated verdict. |
| `-ntpresynccheck` | One specific scripted sequence (session, sync, restart, probe-before-sync, fresh sync, probe-after-sync) for the RTP-timestamp-to-NTP-time sync-reset bug. Prints timestamped markers; verdict computed by the wrapping script (below). |

Scope: connection/session/thread lifecycle and RTP-layer timing. Payload
content is a single real captured AAC-ELD frame repeated, not a genuine
continuous stream — cannot validate whether decoded audio is *audible*,
only whether it's dispatched to the pipeline with correct timing (see
`docs/threadtest.md`'s "Known limitation").

## `tools/test-audio-ntp-resync-e2e.sh` — automated regression test

Requires: Docker only. No Pi, no live client, no human observation.

Builds the current working tree and runs `-ntpresynccheck`, asserting the
RTP-timestamp-to-NTP-time sync-reset behavior is correct. Tests exactly
one revision — the one currently checked out — and never performs a
checkout or revision switch itself. This is the validated template for
this project's bug-fix requirement (see memory: `bug_fix_protocol`):
write the test against the current (fixed) code and confirm it passes;
separately, as a one-time manual step (never automated inside the test),
confirm the same script fails when the affected file is temporarily
swapped to the prior revision. A live reproduction attempt alone is not
sufficient evidence.

## Local image-build checks (no Pi)

Requires: Docker only.

- **`tools/verify-reproducible-build.sh`** — builds `uxplay` twice
  (one `--no-cache`) and asserts the extracted binaries are byte-identical.
- **`tools/vendor-gstreamer-closure.sh`** — computes/vendors the minimal
  GStreamer plugin closure; a build-time tool, not a pass/fail test.
- **`tools/compare-rebuild.sh`** — tiered comparison of a built image
  against a golden-reference snapshot (partition-level, no boot).
- **`image-builder/refresh-apt-lists.sh`** — rare/deliberate: captures a
  fresh `apt-get update` snapshot into `image-builder/apt-lists/`, the
  frozen index `customize-root.sh` installs against instead of querying
  a live mirror. A build-input tool, not a pass/fail test — see
  `apt-packages.lock`'s header for why this exists and how the two must
  be regenerated together.

## Boot-adjacent checks (local Linux container, no real hardware)

Requires: `systemd-nspawn` (a Linux container facility — needs a Linux
host or VM, not plain Docker on macOS).

- **`tools/nspawn-test-boot.sh`** — boots the built root filesystem via
  nspawn: package installs, permissions, systemd unit enablement, how far
  `uxplay_debug` gets before hitting real hardware it structurally cannot
  reach this way (VC4 GPU/KMS, V4L2 hardware decode, real ALSA HDMI).
- **`tools/loop-resize-test.sh`** — tests DietPi's first-boot
  partition/filesystem-resize logic, which nspawn's containerized root
  (no real block device) always skips — needs a real loop-mounted image
  instead.

Scope: everything *except* actual display/decode/audio hardware.

## Real-Pi regression suites

Requires: SSH access to the live device (`192.168.1.34`), which must be
reachable and not mid-use for anything else (see memory:
`no_live_scripts_during_armed_capture`). Each of these stops the live
`uxplay.service`, deploys/replays something, then restarts it.

- **`tools/test-reconnect-e2e.sh`** — generates a synthetic H.264 test
  stream, replays it via `-replay` with a simulated reconnect
  (`UX_RECONNECT_AT_MS`/`UX_RECONNECT_MODE=real`), and asserts `kmssink`
  keeps rendering after the reconnect (via `GST_DEBUG` render-event
  counts). Tests the real hardware decoder/DRM plane reconnect path.
- **`tools/test-render-health-e2e.sh`** — replays every `.cap` file in
  `tools/captures/` via `-replay` and asserts the ratio of `kmssink`
  render events to decode events stays healthy (≥70% by default).
  **Only checks that roughly as many buffers came out as went in — has no
  concept of buffer timing/PTS correctness.** A buffer with a wildly wrong
  timestamp still counts as a render event. Cannot validate or catch any
  bug in the RTP-timestamp-to-NTP-time/PTS computation layer (e.g. the
  bug `tools/test-audio-ntp-resync-e2e.sh` was built for) — and because
  `-replay` feeds back whatever timestamp a capture originally recorded,
  replaying a capture taken *during* a real occurrence of such a bug will
  keep showing that bug's symptom on every future replay regardless of
  which binary replays it, without affecting this suite's render/decode
  count ratio at all.
- **`tools/test-fb0-stays-black-e2e.sh`** — reboots the real device and
  asserts `/dev/fb0` stays zeroed through a real boot sequence. The only
  suite that reboots the Pi; boot-sequence-specific behavior (like this)
  cannot be tested any other way.

## What to use when

- Changing pure logic with no I/O → unit test.
- Changing `conn_request()`/`raop_handler_setup()`/connection or session
  lifecycle, or anything in `lib/raop_rtp.c`'s RTP-timestamp/sync/timing
  path → `-threadtest`/a dedicated `-ntpresynccheck`-style scripted check
  against the current code, validated once (manually, never inside the
  script) to fail against the prior revision.
- Changing video decode/DRM/render-rate behavior → `test-render-health-
  e2e.sh` and/or `test-reconnect-e2e.sh` (real hardware needed).
- Changing boot/provisioning/first-boot scripts → `nspawn-test-boot.sh`
  and/or `loop-resize-test.sh`, plus a real reflash for anything
  boot-sequence-specific (`test-fb0-stays-black-e2e.sh`'s class of bug).
- Changing anything in the audio buffer/PTS/timing computation path →
  **do not rely on `test-render-health-e2e.sh` alone** — it will not
  catch a timing regression in that layer. Write a dedicated test in the
  shape of `tools/test-audio-ntp-resync-e2e.sh` instead.
