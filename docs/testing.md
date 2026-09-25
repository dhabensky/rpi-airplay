# Test framework overview

What each test type actually checks, what it needs to run, and — critically
— what it does *not* check. Read the last column before trusting a "PASS".

## Unit tests — `make unit-tests`

Requires: Docker only. No hardware, no network, no Pi.

`tools/run-unit-tests.sh` compiles and runs each `UxPlay/tests/*.c` file and
each `tools/tests/*.c` file (the wrapper repo's own tooling) inside the shared
tooling image (a non-zero exit/assert failure fails the script):

| Test | Checks |
|---|---|
| `UxPlay/tests/test_raop_conn_policy.c` | `raop_should_teardown_existing_connection()` (`lib/raop_conn_policy.c`) in complete isolation — no GStreamer, no mocking. |
| `UxPlay/tests/test_netlink_addr_watch.c` | `netlink_addr_watch_is_addr_change()` (`lib/netlink_addr_watch.c`) against hand-built netlink messages. |
| `UxPlay/tests/test_on_url_protocol_bounds.c` | `on_url()`'s post-URL protocol read stays inside the bytes fed to `http_request_add_data()` — sweeps request-line split points against a poison-filled buffer. |
| `UxPlay/tests/test_bus_callback_null_renderer.c` | `gstreamer_audio_pipeline_bus_callback()` survives a `GST_MESSAGE_ERROR` when the file-static `renderer` is `NULL` — links `renderers/audio_renderer.c` directly. |
| `UxPlay/tests/test_release_display_epoch_guard.c` | `video_renderer_release_display()`'s deferred hide no-ops when a reconnect bumped the epoch first — links `renderers/video_renderer.c` and uses the real `g_idle_add()` dispatch. |
| `UxPlay/tests/test_event_fifo_nonblocking.c` | `-efifo`'s writes (`UxPlay/event_fifo.c`) never block or kill the process: opening with no reader, flooding a FIFO nobody reads, emitting after the reader left, refusing a regular file at the path, and strict begin/end alternation of delivered lines under two contending emitter threads. Installs no SIGALRM/SIGPIPE handler, so either failure is a fatal signal. |
| `tools/tests/test_uxplay_menu_parse.c` | `uxplay-menu`'s two inputs (`tools/uxplay-menu-parse.c`): the event-FIFO drain against a real FIFO (split, unknown, over-long lines, a backlog bigger than the pipe) and `/etc/default/uxplay` parsing against real files. |

Scope: pure-function/single-callback correctness, plus contention on one
self-contained module (`event_fifo.c`). Cannot exercise the real session
threads, timing, a running GStreamer pipeline or real network I/O.

## `tools/synthetic-client.cpp` — standalone test-client, real-server tests

Requires: Docker (`tools/build-uxplay.sh` also builds this binary
alongside `uxplay_debug`, same source directory, same command). Run as a
genuinely separate process from an unmodified `uxplay_debug` -- e.g.
`docker exec <container> /usr/local/bin/synthetic-client threadtest N
--port <raop_port>` against a container already running `uxplay -vs 0
-ble <file>` (see `tools/pytest/conftest.py`'s `TwoProcessRunner` for the
exact pattern the pytest suite below uses). No Pi hardware needed for the
audio path (`-vs 0` skips video/DRM entirely).

The image also ships the binary at `/usr/local/bin/synthetic-client`, so the
same modes can be driven against the live `uxplay.service` on the real device
(real `alsasink`, real hardware decoder, real DRM planes) without deploying a
binary. `mirrortest` additionally needs a `.cap` frame fixture, which is *not*
in the image (`tools/captures/` is local test data) -- copy one over first and
point `--frames-cap` at it, otherwise it exits 1 with `load_mirror_frames:
cannot open tools/captures/trimmed/...`:

```bash
scp tools/captures/trimmed/personalmac-stall-20260911-10s.cap root@<pi>:/root/
# then, on the Pi:
PORT=$(ss -tlnp | grep uxplay_debug | awk '{print $4}' | sed 's/.*://' | sort -n | head -1)
/usr/local/bin/synthetic-client mirrortest 1 --port "$PORT" \
  --frames-cap /root/personalmac-stall-20260911-10s.cap
```

The other modes need no fixture. Use `drmdump` (also shipped) to check what
the session actually put on screen. `/var/log/uxplay.log` is timestamped
(UTC, ms), so its lines correlate directly with anything else timestamped.

This is a standalone binary, not a flag baked into `uxplay.cpp` -- moved
out entirely (see `docs/threadtest.md`) so the server under test is
always the real, unmodified shipped binary, and the "fake AirPlay client"
is a real, separate OS process talking real RTSP/RTP over loopback, not a
thread sharing the server's own address space.

| Mode | Checks |
|---|---|
| `threadtest N [--gap-s S]` | Connection/session lifecycle across N real SETUP/TEARDOWN cycles (rapid or gap-spaced): no orphaned `raop_rtp_t` objects, deferred-callback timing, decode-buffer counts. Exploratory/manual — prints diagnostics, no automated verdict. |
| `ntpresync` | One specific scripted sequence (session, sync, restart, probe-before-sync, fresh sync, probe-after-sync) for the RTP-timestamp-to-NTP-time sync-reset bug. Prints timestamped markers; verdict computed by the wrapping test (below). |
| `resendstorm` / `resendrecovery` | Resend-request-rate and end-to-end recovery-time checks for the audio resend-flood bug (see `docs/bugs/2026-09-14-audio-resume-latency-on-seek.md`). |

Scope: connection/session/thread lifecycle and RTP-layer timing. Payload
content is a single real captured AAC-ELD frame repeated, not a genuine
continuous stream — cannot validate whether decoded audio is *audible*,
only whether it's dispatched to the pipeline with correct timing (see
`docs/threadtest.md`'s "Known limitation").

## `tools/pytest/` — the e2e regression suite

Run with `make pytest`, which bootstraps the project-local venv
(`tools/pytest-setup.sh` -- Homebrew's system Python is externally-managed,
PEP 668) and skips everything needing the real device. `make pytest
PYTEST_MARK=` includes those, `PYTEST_ARGS` passes flags through (`-v`,
`-k ...`).

Replaced the old `tools/test-*-e2e.sh` scripts (same coverage, same
underlying mechanisms -- Docker `-threadtest`/`-ntpresynccheck`/
`-resendstormcheck` drivers, real-Pi `-replay`/reboot checks -- just
converted to pytest, since ad-hoc bash-plus-inline-Python heredocs don't
compose or report well at 7+ scripts). `test_ntp_resync.py`,
`test_resend_storm.py`, and `test_reconnect_latency.py` were later moved
again, off the in-process `-threadtest`/`-ntpresynccheck`/
`-resendstormcheck` driver flags entirely, onto
`tools/synthetic-client.cpp` (above) -- driving an unmodified
`uxplay_debug` as a genuinely separate process via the `two_process_runner`
fixture, instead of a thread compiled into the server's own binary.

Every test still targets exactly ONE server binary per run --
`--uxplay-ref <git-ref>` builds a specific UxPlay submodule commit
instead of the current working tree (via a throwaway `git worktree`,
cached per ref; defaults to the `dhabensky-clean-2` branch this repo's
`.gitmodules` tracks), so demonstrating a bug and its fix is "run the
whole suite twice": once with `--uxplay-ref <parent-of-fix-commit>` (real
failures expected) and once against current HEAD (PASS expected) -- not
a parametrized test that already knows about both.
`tools/synthetic-client.cpp` itself is always built from the current
working tree regardless of `--uxplay-ref` (`synthetic_client_binary`
fixture) -- it's test infrastructure talking real wire protocol to
whatever server is under test, not part of what a before/after comparison
varies. See `tools/pytest/reports/` for real before/after evidence
(revisions tested, actual logs, rendered pictures, and a genuine written
interpretation) gathered for each test -- including honest flags on which
tests' usefulness could and couldn't be confirmed this way.

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
  path → `synthetic-client threadtest`/a dedicated `ntpresync`-style scripted check
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
