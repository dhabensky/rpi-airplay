# Test framework overview

What each test type actually checks, what it needs to run, and — critically
— what it does *not* check. Read the last column before trusting a "PASS".

## Unit tests — `make unit-tests`

Requires: Docker only. No hardware, no network, no Pi.

`tools/run-unit-tests.sh` compiles and runs each `UxPlay/tests/*.c` file
inside the shared tooling image (a non-zero exit/assert failure fails
the script):

| Test | Checks |
|---|---|
| `test_raop_conn_policy.c` | `raop_should_teardown_existing_connection()` (`lib/raop_conn_policy.c`) in complete isolation — no GStreamer, no mocking. |
| `test_bus_callback_null_renderer.c` | `gstreamer_audio_pipeline_bus_callback()` survives a `GST_MESSAGE_ERROR` when the file-static `renderer` is `NULL` — links `renderers/audio_renderer.c` directly. |

Scope: pure-function/single-callback correctness. Cannot exercise
threading, timing, or anything that needs a running GStreamer pipeline or
real network I/O.

## `-threadtest N` / `-ntpresynccheck` — synthetic-client, real-server tests

Requires: Docker (`make uxplay`) to build; runs via `docker run -v
"$PWD/build/uxplay_debug":/usr/local/bin/uxplay:ro rpi-airplay-buildenv
/usr/local/bin/uxplay -vs 0 -threadtest N` (or `-ntpresynccheck`). No Pi
hardware needed for the audio path (`-vs 0` skips video/DRM entirely).
Can also run on the Pi for a real `alsasink` instead of `autoaudiosink`.

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

## `tools/pytest/` — the e2e regression suite

Requires: `tools/pytest-setup.sh` once (builds a project-local venv --
Homebrew's system Python is externally-managed, PEP 668). Run with
`tools/pytest/.venv/bin/pytest tools/pytest/ -v`, or `-m "not
pi_hardware"` to skip everything needing the real device.

Replaced the old `tools/test-*-e2e.sh` scripts (same coverage, same
underlying mechanisms -- Docker `-threadtest`/`-ntpresynccheck`/
`-resendstormcheck` drivers, real-Pi `-replay`/reboot checks -- just
converted to pytest, since ad-hoc bash-plus-inline-Python heredocs don't
compose or report well at 7+ scripts). Every test still targets exactly
ONE binary per run -- `--uxplay-ref <git-ref>` builds a specific UxPlay
submodule commit instead of the current working tree (via a throwaway
`git worktree`, cached per ref), so demonstrating a bug and its fix is
"run the whole suite twice": once with `--uxplay-ref
<parent-of-fix-commit>` (real failures expected) and once against
current HEAD (PASS expected) -- not a parametrized test that already
knows about both.

Every test also writes a Perfetto trace (Chrome Trace Format JSON,
`--trace-dir`, default `build/traces/`) built from the exact timestamped
marker lines the test already parses to make its assertion -- open it at
ui.perfetto.dev to see the failure shape directly (a counter track's
"decoded" line climbing while "rendered" flatlines, a duration bar's
width, ...) instead of trusting a printed PASS/FAIL. See each test
module's own docstring for what its trace actually shows and, where
relevant, which bugs it's confirmed CANNOT be demonstrated this way (the
render-collapse bug in particular needs live real-time RTSP timing that
`-replay` structurally cannot reproduce -- confirmed directly, not
assumed).

| Module | Mirrors (old script) | Needs Pi |
|---|---|---|
| `test_ntp_resync.py` | `test-audio-ntp-resync-e2e.sh` | no |
| `test_reconnect_latency.py` | `test-audio-reconnect-latency-e2e.sh` | no |
| `test_resend_storm.py` | `test-audio-resend-storm-e2e.sh` | no |
| `test_fb0_stays_black.py` | `test-fb0-stays-black-e2e.sh` | yes (reboots it) |
| `test_video_reconnect.py` | `test-reconnect-e2e.sh` | yes |
| `test_render_health.py` | `test-render-health-e2e.sh` | yes |
| `test_resolution_change_gap.py` | (new, 2026-09-15) | yes |

This is still the validated template for this project's bug-fix
requirement (see memory: `bug_fix_protocol`): a test written against the
current (fixed) code that also demonstrably fails against the prior
revision is stronger evidence than a live reproduction attempt alone --
now a real `--uxplay-ref` run instead of a one-time manual step.

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
- **`tools/refresh-buildenv-apt-lists.sh`** — same fix, for `Dockerfile`'s
  own build-tooling packages (a different apt source: the plain Debian
  base image's, not the customized DietPi rootfs's) — captures into the
  top-level `apt-lists/`.

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

## Real-Pi regression suites (`pytest -m pi_hardware`)

Requires: SSH access to the live device (`192.168.1.34`, `--pi-host` to
override), which must be reachable and not mid-use for anything else
(see memory: `no_live_scripts_during_armed_capture`). Each of these
stops the live `uxplay.service`, deploys/replays something, then
restarts it (`pi_uxplay_deployed` fixture, `tools/pytest/conftest.py` --
restores the service in a `finally`, regardless of pass/fail).

- **`test_video_reconnect.py`** — generates a synthetic H.264 test
  stream, replays it via `-replay` with a simulated reconnect
  (`UX_RECONNECT_AT_MS`/`UX_RECONNECT_MODE=real`), and asserts `kmssink`
  keeps rendering after the reconnect (via `GST_DEBUG` render-event
  counts). Tests the real hardware decoder/DRM plane reconnect path.
- **`test_render_health.py`** — replays every `.cap` file in
  `tools/captures/trimmed/` via `-replay` and asserts the ratio of
  `kmssink` render events to decode events stays healthy (≥70% by
  default). **Only checks that roughly as many buffers came out as went
  in — has no concept of buffer timing/PTS correctness.** A buffer with a
  wildly wrong timestamp still counts as a render event. Cannot validate
  or catch any bug in the RTP-timestamp-to-NTP-time/PTS computation layer
  (e.g. the bug `test_ntp_resync.py` was built for) — and because
  `-replay` feeds back whatever timestamp a capture originally recorded,
  replaying a capture taken *during* a real occurrence of such a bug will
  keep showing that bug's symptom on every future replay regardless of
  which binary replays it, without affecting this suite's render/decode
  count ratio at all. Also confirmed (2026-09-15) unable to reproduce a
  real-time-RTSP-timing-dependent render collapse at all, regardless of
  binary -- see the module's own docstring.
- **`test_resolution_change_gap.py`** — replays a 1s fixture
  (`tools/captures/resolution-change-gap-repro.cap`) and measures how
  many frames decode before `kmssink` resumes rendering after the one
  normal mid-stream resolution-change renegotiation every session goes
  through. `--extra-uxplay-args=-bt709` repeats the comparison that
  proved that flag doesn't help (docs/bugs/2026-09-14-video-render-
  collapse.md).
- **`test_fb0_stays_black.py`** — reboots the real device and asserts
  `/dev/fb0` stays zeroed through a real boot sequence. The only suite
  that reboots the Pi; boot-sequence-specific behavior (like this) cannot
  be tested any other way. No `uxplay_binary`/`--uxplay-ref` here -- the
  bug lives in `image-builder/`, not the uxplay binary.

## What to use when

- Changing pure logic with no I/O → unit test.
- Changing `conn_request()`/`raop_handler_setup()`/connection or session
  lifecycle, or anything in `lib/raop_rtp.c`'s RTP-timestamp/sync/timing
  path → `-threadtest`/a dedicated `-ntpresynccheck`-style scripted check
  (`test_ntp_resync.py`, `test_reconnect_latency.py`), validated with
  `--uxplay-ref` against the prior revision to confirm it actually fails
  there.
- Changing video decode/DRM/render-rate behavior → `test_render_health.py`
  and/or `test_video_reconnect.py` (real hardware needed).
- Changing boot/provisioning/first-boot scripts → `nspawn-test-boot.sh`
  and/or `loop-resize-test.sh`, plus a real reflash for anything
  boot-sequence-specific (`test_fb0_stays_black.py`'s class of bug).
- Changing anything in the audio buffer/PTS/timing computation path →
  **do not rely on `test_render_health.py` alone** — it will not catch a
  timing regression in that layer. Write a dedicated test in the shape of
  `test_ntp_resync.py` instead.
