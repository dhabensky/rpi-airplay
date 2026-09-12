# RPi3B+ AirPlay Receiver — Progress Summary

## Goal
Raspberry Pi 3 Model B+ as a dedicated AirPlay receiver (UxPlay) plugged into a TV's
HDMI input, so a MacBook can screen-mirror movies to it. Latency doesn't matter;
audio/video sync does. Pi joins the home WiFi as a normal client (not a standalone
hotspot — MacBook needs simultaneous internet access).

## Current hardware/network facts
- Pi IP: `192.168.1.34`, hostname `rpi-airplay`, SSH: `root@192.168.1.34` / password `pizza`
- WiFi: `AKADO-AD88-5G` (same network as the Mac)
- SD card: 2GB, verified reliable via checksum test (an earlier "32GB" card was
  counterfeit/corrupted — see below)
- `reboot` command over SSH throws a `dbus-org.freedesktop.login1.service` error but
  the reboot proceeds anyway (broken but harmless D-Bus unit) — ignore the error text

## What's built
- **Base OS**: DietPi (Debian 13 Trixie, ARM64), heavily trimmed:
  - `/usr/lib/firmware` cut from 397MB → 20MB (kept only `brcm`/`cypress` for the
    Pi's actual WiFi/BT chip)
  - docs/man/non-English locale stripped
  - Base image: 1129MB total, ~490MB actually used after all our additions — huge
    headroom on a 2GB card
- **UxPlay**: built from source at **v1.73.7 (stable tag)** — NOT master/1.74
  ("Experimental"), which has a real, reproducible appsrc race-condition bug that
  crashes on connect. Repo: `github.com/FDH2/UxPlay`, cloned into
  `UxPlay/` in this project dir.
- **GStreamer runtime**: hand-picked minimal closure (198 files, ~187MB) via real
  `ldd` dependency resolution, NOT `apt install` — plain `apt install
  gstreamer1.0-plugins-good/bad` pulls 350+ packages / 750MB+ of X11/Wayland/dbus/
  PulseAudio/ONNX-runtime/OpenEXR bloat completely unrelated to our headless
  kmssink+v4l2+alsa pipeline. Build/closure-export tooling lives in
  `Dockerfile.uxplay-buildtest`, `export_closure.py`, `closure_calc.py` and the
  `gst_fix/` directory (extracted individual plugin files pushed to the Pi as
  needed: `libgstautodetect.so`, `libgstlevel.so`, `libgstdebug.so` (provides
  `capssetter`), `liborc-0.4.so.0`, etc. — GStreamer plugins-good bundles many
  unrelated elements into single .so files; UxPlay's actual pipeline string needs
  more of them than initially obvious).
- **Local build sandbox**: colima (ARM64 Linux VM, native — no emulation needed
  since host is Apple Silicon) + Docker, used for all cross-builds. `LIMA_HOME=~/.colima/_lima`
  needed for `limactl` to see colima's instance.
- **Regression test**: `UxPlay/tests/test_bus_callback_null_renderer.c` — reproduces
  the null-`renderer` crash in `audio_renderer.c`'s bus callback locally (no Pi
  needed), proven to crash pre-fix (exit 139) and pass post-fix (exit 0).

## Source patches applied to UxPlay (all in `UxPlay/renderers/*.c`)
1. **Video race condition** (`video_renderer.c`): added an atomic
   `video_renderer_ready` flag, cleared at the start of `video_renderer_init()`,
   set only after `video_renderer_start()` confirms every pipeline's state
   transition actually left `GST_STATE_CHANGE_ASYNC` (not just after one timed
   wait). `video_renderer_render_buffer()` now checks this flag before touching
   `renderer->appsrc`. Root cause: `kmssink`'s DRM setup can block the main
   thread for multiple seconds on this hardware; the RTP mirror thread would
   start pushing buffers before init finished, racing on the same GstElement →
   segfault deep in `libgstapp`.
2. **Null-renderer crashes** in both `audio_renderer.c` and
   `video_renderer.c`'s `GST_MESSAGE_ERROR`/`STATE_CHANGED` bus-callback
   handlers: `renderer->appsrc`/`renderer->pipeline` were dereferenced without
   checking `renderer` itself for NULL. This is a real, pre-existing latent bug:
   the bus watch is attached per-pipeline before codec (h264/h265) selection
   picks which becomes the active `renderer`, so a message on a not-yet-selected
   pipeline (or during teardown) crashed. Fixed with `if (renderer && ...)` guards
   in both files (video's `autovideo` check on every STATE_CHANGED message was
   the highest-frequency trigger).
3. **Unbounded queue** (`video_renderer.c`): the video pipeline's `queue` element
   had zero properties (GStreamer defaults: ~200 buffers/10MB/1s). Changed to
   `max-size-buffers=0 max-size-bytes=0 max-size-time=0`. This measurably
   extended real-frame delivery from ~10s to 30-380+ seconds before client
   fallback — real fix, not fully proven sufficient alone (see open items).

## Infrastructure bugs found & fixed on the Pi itself
- **`bcm2835_codec` (hardware H.264 decode) is blacklisted by DietPi by default**
  via `/etc/modprobe.d/dietpi-disable_rpi_codec.conf` — removed it. Also needed
  `/etc/modules-load.d/bcm2835-codec.conf` for boot-time autoload (confirmed
  persists through real reboots) and a udev rule
  (`/etc/udev/rules.d/99-bcm2835-codec.rules`:
  `SUBSYSTEM=="video4linux", GROUP="video", MODE="0660"`) since `/dev/video1x`
  defaults to `root:root 0600`.
- **Power supply under-voltage**: original PSU caused `vcgencmd get_throttled` →
  `0x50005` (under-voltage + throttled, ARM clocked down to 600MHz vs 1.4GHz
  rated). A different power source fixed it (`throttled=0x0`, full clock). This
  was the reason video ran at ~0.5-1fps before the fix — always check
  `vcgencmd get_throttled`/`measure_clock arm` first on any RPi performance issue.
- **ALSA HDMI audio**: device is `hw:vc4hdmi,0` / `plughw:vc4hdmi,0` (single-port
  3B+, confirmed via `/proc/asound/cards`). `uxplay`'s `alsasink` needs to be
  pointed at it explicitly (`-as "alsasink device=plughw:vc4hdmi,0"`) since
  there's no PipeWire/PulseAudio default-device concept on this minimal image.
- **`getty@tty1.service` was masked** to stop the DietPi login prompt from
  fighting uxplay for the console — this did NOT actually cause any of the
  later "no video" issues (verified by later DRM-level analysis showing correct
  compositing regardless of getty state); don't re-investigate this path.
- **avahi-daemon** installed (`apt install avahi-daemon`) for mDNS since DietPi's
  minimal image doesn't ship it; UxPlay 1.73.7 requires it unconditionally
  (unlike master/1.74's optional built-in mDNS responder).
- **systemd service** (`/etc/systemd/system/uxplay.service`): runs as a
  dedicated non-root `uxplay` system user (member of `video`,`render`,`audio`,
  `input` groups — created via `useradd -r -M -s /usr/sbin/nologin`), NOT root
  (per UxPlay's own README guidance). Has `Environment=HOME=/home/uxplay` +
  `GST_REGISTRY=...` since the user has no real home dir by default (had to
  `mkdir -p /home/uxplay` manually). Output redirected straight to
  `/var/log/uxplay.log` via `StandardOutput=append:...` + `ExecStart=/usr/bin/stdbuf
  -oL -eL ...` — **journald silently rate-limits uxplay's high-volume per-packet
  logging**, making it look like connections produce zero log output; always use
  the file+stdbuf approach for real diagnostics, not `journalctl`.
- **macOS ControlCenter Screen Recording permission**: added manually via
  System Settings → Privacy & Security → Screen Recording → `+` →
  `/System/Library/CoreServices/ControlCenter.app`, then full Mac restart.
  Fixed one instance of "only wallpaper, no windows" but this state has
  recurred since for reasons not yet fully isolated from macOS-side factors
  (VPN client `hidemy.name` was also found running — quitting it had no
  effect, but a WiFi toggle on the Mac once did unstick a stuck session).

## Verified via direct DRM inspection (`modetest -M vc4 -p`, `/sys/kernel/debug/dri/0/state`)
As of the last check, the rendering pipeline is **provably correct** at the
kernel/DRM level:
- `plane-3` (id 86, **Primary**, owned by kernel `fbcon`): zpos=0 (immutable),
  showing a static leftover frame (`fb=671`) frozen since getty was disabled —
  this is cosmetic, not a bug.
- `plane-4` (id 98, **Overlay**, owned by `v4l2h264dec0`): zpos=1, alpha=65535
  (fully opaque) — actively, continuously updating (confirmed via `kmssink`
  debug log showing DMA-BUF import + alternating `fb=672/674` for 60+ seconds
  straight during a live session).
- Since overlay zpos(1) > primary zpos(0), the video plane legitimately
  composites **on top of** fbcon's static plane per standard DRM rules. There
  is no compositing bug. `uxplay_debug` correctly holds DRM master
  (`/sys/kernel/debug/dri/0/clients`), no competing process.
- **Forcing `kmssink plane-id=86`** (i.e., onto fbcon's own primary plane) was
  tried and immediately broke pipeline negotiation (`Internal data stream
  error`) — plane 86 is locked to fbcon's RG16 format, incompatible with
  kmssink's own output formats. Do not retry this; the default auto-selected
  overlay plane (98) is correct.
- **Real frame data confirmed flowing** at the network+decode level across
  multiple tests: packet type `0x00` (real H.264 VCL data) with varying sizes
  (up to 923 frames / 379 seconds continuous in one test), vs. type `0x05`
  ("video streaming performance info" / locked-screen-style status packets,
  which the client falls back to after some period — up to several minutes in
  the best test, ~10s in the worst).
- **UxPlay has zero cursor-rendering code** (confirmed via grep across
  `uxplay.cpp`/`raop_rtp_mirror.c`/`video_renderer.c`) — the cursor will never
  appear in the mirrored output. This is an inherent UxPlay limitation, not a
  bug to chase further.

## 2026-09-06 session: root causes found, most prior conclusions OVERTURNED

**The "only desktop" mystery was a macOS SENDER setting, not a Pi bug.** The Mac
was configured to use the AirPlay device as a *separate/extended* display
("other display") instead of *mirror*. The Pi was correctly showing an empty
extended desktop; the browser was on the Mac's own screen. Switching macOS to
**mirror** made the real content appear immediately. (Proven independently: the
raw received H.264 stream, dumped with `-vdmp` and decoded with `ffmpeg` on the
Pi, showed the exact browser/movie content — the sender was always sending
correct 1080p frames.)

**Corrections to earlier claims in this file:**
- The "overlay composites correctly / pipeline provably correct at DRM level"
  section below is misleading. The old default pipeline (`decodebin ! videoconvert`)
  was in fact BROKEN: on this GStreamer (1.24+, kernel 6.18) the v4l2 decoder
  outputs `video/x-raw(memory:DMABuf),format=DMA_DRM,drm-format=YU12`, which the
  **software `videoconvert` cannot negotiate** (`transform could not transform ...
  DMA_DRM ... in anything we support` + `could not send sticky events`) — so with
  the shipped service args (`-bt709 -vs kmssink`, no `-v4l2`) real video never
  rendered at all.
- The "client falls back 0x00→0x05" framing (old open item #2) was a
  misdiagnosis. With a working pipeline, the client keeps sending real frames
  (~1 Mbit/s confirmed) — video freezes were **Pi-side**. The `0x05`
  "performance info" packets and tiny 110-byte `0x00` frames just mean the Mac's
  screen was **static** at that moment (AirPlay is change-driven: a still desktop
  ≈ 2-3 tiny frames/sec; that is NOT a decode-rate measurement).
- Power/throttling is NOT a current factor: `throttled=0x0`, h264 block 300 MHz,
  core 400 MHz, temp ~46 °C, gpu_mem 128 MB.
- **The hardware is fully capable**: offline `ffmpeg` benchmark on a real dumped
  1080p clip → `h264_v4l2m2m` HW decode **~48 fps**, software ~54 fps (both ~2×
  realtime). Playing the same dump straight to `/dev/fb0` (primary plane, via
  `ffmpeg -f fbdev`) is **smooth and visibly faster than live mirroring** — so
  decode + display hardware are fine; the whole problem was the live GStreamer
  sink path.

**Actual root causes of the "laggy / desync" mirroring, and the fixes:**
1. Missing `-v4l2` in the service (converter was software `videoconvert`, which
   can't take the decoder's DMABuf) → **use `-vc identity`** (or `v4l2convert`).
   `identity` = zero conversion: `v4l2h264dec` YU12 DMABuf goes straight through
   `videoscale` (passthrough at 1080→1080) to kmssink, which the VC4 overlay/
   scanout converts YUV→RGB for free.
2. **kmssink was using an OVERLAY plane that was slow (~15 fps).** Adding
   `force-modesetting=true` moves kmssink onto the **primary plane** (like the
   working fbdev path). This is what makes plane-86 usable — the old "forcing
   plane-id=86 breaks with RG16 lock" note was because fbcon still owned it;
   `force-modesetting` does its own modeset and takes the CRTC.
3. Removing `v4l2convert` (the 2nd HW M2M colour pass) raised throughput
   **15 → 24 fps** (source is 1080p **25 fps**), i.e. ~realtime → the *growing*
   A/V desync stopped (video now keeps up with audio).

**Current best working config** (via the `/usr/local/bin/uxrun` helper, base args):
`uxplay -vd v4l2h264dec -vc identity -srgb no -vsync no -vs "kmssink force-modesetting=true" -as "alsasink device=plughw:vc4hdmi,0"`
→ smooth 24 fps, real content, desync **constant (not growing)**.

## 2026-09-06 (later): A/V sync nailed down + capture/replay harness

**Ground truth from real traffic (definitive):** captured a real mirror session of
a test clip (full-white flash + loud audio accent every 2s) and read UxPlay's `-d`
per-packet log — the flash shows as a big video packet, the accent as a big audio
packet, both with arrival `now`. Result: **audio and video arrive at the Pi in
sync, within ~100ms** (audio ~0.1s ahead). So the sender (Mac, QuickTime/YouTube)
and the network are fine — the earlier "2s" was NOT the source. The desync is
entirely Pi-side playback, and it is CONSTANT (never grew — earlier "growing"
reports were different configs / the silence-underrun gurgle, not drift).

**A/V sync is now essentially solved for steady playback:**
- Real offset (with the working pipeline) is only **~0.2s, audio slightly behind**
  (≈ the alsasink buffer). User-confirmed optimal correction = **delay video by 9
  compressed frames** (~0.34s). Audio CANNOT be advanced (`-vsync` negative just
  drops it; its buffer is at the floor), so the fix is a small VIDEO delay, done
  in the compressed domain before the decoder (`-vp "h264parse ! queue
  max-size-...=0 min-threshold-buffers=9"`) — this is the only video-delay that
  works (post-decoder buffering exhausts the v4l2 DMABuf capture pool → green
  screen; kmssink `ts-offset` breaks sync).
- **Baked into `/etc/systemd/system/uxplay.service`** (enabled, autostarts):
  `uxplay_debug -vp "h264parse ! queue max-size-buffers=0 max-size-bytes=0 max-size-time=0 min-threshold-buffers=9" -vd v4l2h264dec -vc identity -srgb no -vsync no -n "Living Room TV" -reset 60 -vs "kmssink force-modesetting=true" -as "alsasink device=plughw:vc4hdmi,0"`
- **`/usr/local/bin/uxrun N`** helper = live A/V-sync knob (N = video-delay frames,
  ~38ms each); restart + reconnect to apply.

**Gotcha — silence causes gurgle, NOT a real bug:** a mostly-silent test clip
made audio "булькать"/drop, because macOS suppresses AirPlay audio during silence
and the alsasink underruns. Real (continuous-audio) content is clean. Don't chase
it; test A/V sync with CONTINUOUS audio (e.g. steady noise + a loud accent marker),
not gated beeps/clicks.

**Still open — seek/pause transients.** On seek/restart the pre-seek audio keeps
playing (>1s tail) and briefly desyncs. UxPlay's `audio_renderer_flush()` /
`video_renderer_flush()` are BOTH empty (authors avoided flushing to prevent
artifacts). Implementing an appsrc `flush_start`/`flush_stop(FALSE)` in
audio_renderer_flush did NOT help and likely breaks the segment (audio stalls) —
reverted. This is largely AirPlay's ~1-2s audio pre-buffer draining; not solved.

**Capture/replay harness (for autonomous e2e testing without the Mac):** added to
UxPlay source (behind flags), since AirPlay MIRROR sending can't be automated (no
CLI/OSS mirror sender; macOS Control-Center osascript is perms-blocked; raw
tcpdump replay fails — per-session crypto keys):
- `-capture <file>` records every DECRYPTED video/audio frame + ntp + flush events
  (hooks in `audio_process`/`video_process`/`*_flush`/`audio_get_format` in
  uxplay.cpp; format `[type:1][mono_ns:8][ntp:8][len:4][data]`). **Works** (a real
  session was captured to `/tmp/session.cap`, 4.6MB).
- `-replay <file>` feeds the capture back into the real GStreamer pipelines at the
  original timing via a feeder thread + GMainLoop. **WORKS NOW**: video renders
  (fb flips continuously) and audio plays through the whole session, fully
  autonomous (no AirPlay/Mac). The fix was calling **`video_renderer_choose_codec(false,false)`**
  in `replay_run()` — live this is done by the RAOP `video_set_codec` callback;
  it selects the active h264 renderer (otherwise `renderer` stays NULL) and moves
  its pipeline to PLAYING (`video_renderer_start` only sets PAUSED + sets
  `renderer=NULL`; the real PLAYING/renderer-selection happens in
  `video_renderer_choose_codec`, video_renderer.c:559/584). The earlier "audio
  stalls at 6.6s" was a red herring — that was just the AVSYNC accent-marker
  probe going quiet on quieter audio, not a stall.
- **`capx`** (source `capx.c`, compile via `docker run --rm -v "$PWD":/w -w /w
  uxplay-build gcc -O2 -o capx capx.c`; ARM64, runs on Pi): parses a `.cap` file.
  `capx f.cap` → record stats (V/A/C/flush counts, mono span); `capx f.cap v >
  out.h264` → extract the h264 elementary stream (validated: decodes in ffmpeg).
- AV-sync marker probe `install_av_sync_probe` (opt-in `UX_PROBE=1`): detects the
  test clip's white-flash video frame + loud audio accent by buffer content and
  logs `AVMARK video/audio t=<ms>`. Works, but the probe fires at the sink PAD
  (arrival), which for `-vsync no` ≈ render for video but MISSES alsasink's ~196ms
  internal latency for audio — add ~196ms to audio marker times for true output.
- Captured sessions on the Pi: `/tmp/youtube.cap` (real YouTube w/ a seek, no
  sync markers), `/tmp/session.cap` (earlier). NOTE: an AirPlay **seek** is a
  TEARDOWN + re-SETUP of the audio connection (shows as a 2nd `C` ct-record in the
  capture), NOT a RAOP FLUSH; a **pause** is a FLUSH. `audio_renderer_flush` was
  given a whole-pipeline `flush_start`/`flush_stop(TRUE)` impl (drops buffered
  audio on pause/seek) — deployed but not yet verified to help.
- **Replaying `/tmp/youtube.cap` shows CONTINUOUS A/V through the seek point** (no
  audio dropout, video fb flips throughout). So the frame-level replay does not
  reproduce the live seek desync — the live seek offset likely comes from the
  `remote_clock_offset` / ntp re-sync path that replay bypasses (`-vsync no`,
  timestamps ignored). To measure/fix seek autonomously, capture the flash+accent
  TEST CLIP (`avsync_cont.mp4`) *with a seek*, then replay + `UX_PROBE=1` to read
  the pre/post-seek A/V offset from AVMARK. (Synthesising such a capture is blocked
  by needing AAC-ELD audio frames, which the mp4's AAC-LC isn't; NFORMATS=2 so
  only AAC-ELD + ALAC pipelines exist.)

**Objective measurement tools proven this session:**
- `ffmpeg` benchmark on a dumped clip: HW `h264_v4l2m2m` decode ~48fps, SW ~54fps
  (both ~2x realtime) → decode is NOT a bottleneck.
- `ffmpeg -f fbdev /dev/fb0` playback of a dump = smooth → display HW fine.
- `snd-aloop` + `arecord` available for capturing true audio output (not yet wired
  into the harness).
- ALSA true latency: `/proc/asound/card0/pcm0p/sub0/status` → `delay` ≈ 8500
  frames ≈ 196ms, `hw_ptr` advances at exactly 44100/s (no clock drift). Device is
  44100 (matches AAC-ELD; audioresample is passthrough).

## 2026-09-06 (latest): SEEK root cause found autonomously via the harness

The replay harness now works end-to-end. Captured the flash+accent test clip
WITH a seek (`/tmp/marked.cap`) and replayed it with `UX_PROBE=1`. Video-flash
detection had to be changed from average-luma to **fraction of bright Y pixels**
(>15% of the Y plane > 200), because the user mirrors the whole desktop with the
player in a *window* (not fullscreen), so the flash only whitens part of the
frame — see the captured frame: QuickTime windowed + YouTube + terminal visible.

**Result (objective, autonomous):**
- Video flash markers fire every ~2s for the WHOLE session, INCLUDING across the
  seek (…16426 → 18842 → 20844…): **video is NOT interrupted by a seek.**
- Audio markers have a **~3.4 s gap at the seek** (…16410 → [gap] → 19822…):
  **audio reception drops for ~3.4s during the AirPlay seek** (TEARDOWN +
  re-SETUP of the audio connection; the capture has a real ~3.4s gap in audio
  records there), then resumes. Video keeps playing → that's the "seek breaks
  sync" the user sees.
- Pre-seek steady A/V offset ≈ 0.2s (matches the QuickTime/YouTube steady case
  that the 9-frame delay already corrects).
- Could NOT measure the exact POST-seek residual offset: macOS amplifies the
  mirrored system audio so BOTH the clip's quiet baseline and loud accent clip at
  32767 — amplitude can't separate them (APROBE peak ≈ 32727 constant). A future
  test clip needs a quiet track (or a frequency-coded accent + FFT in the probe).

**So the seek issue is a ~3.4s AUDIO DROPOUT during the AirPlay audio
teardown/re-setup on seek — largely sender/protocol-side (the receiver simply
isn't sent audio for that window), which the Pi can't fill.** Whether the audio
resumes perfectly in sync afterwards is not yet measured (clipping, above).
Possible Pi-side angle to explore later: make the audio teardown/re-SETUP path
faster / not lose the first post-seek audio (deep RAOP/RTSP work in lib/), and/or
verify post-seek resync with a non-clipping marked clip.

## 2026-09-07: sync=true is a DEAD END for live; seek still open

- **`sync=true` (timestamp A/V sync) works in the replay harness but BREAKS the
  LIVE path**: video freezes and doesn't reappear on disconnect/reconnect. Cause:
  live video goes through `video_process`'s `remote_clock_offset` / pts-mismatch
  do-while loop (video_renderer.c:704+, uxplay.cpp:2344), which conflicts with
  sync=true (pts < base_time on (re)connect → never converges). The harness
  bypasses that loop (feeds `video_renderer_render_buffer` directly), so it
  looked fine there. **REVERTED.** Do not ship sync=true without reworking the
  clock/base_time handling.
- **Reverted to the known-good config** in the service (confirmed-good
  steady-state): `-vp "h264parse ! queue ...=0 min-threshold-buffers=9" -vd
  v4l2h264dec -vc identity -srgb no -vsync no -vs "kmssink force-modesetting=true"
  -as "alsasink device=plughw:vc4hdmi,0"`. `uxrun N` = frame-delay knob again.
- **Seek analysis (via `capx` on the marked capture):** on each AirPlay seek the
  audio stream has a **~3s gap** (`A gap=2.96s before t=21.05`, again at 28.49),
  and BETWEEN seeks audio is continuous/realtime (NOT a catch-up burst — so a
  leaky audio queue won't help). The ~3s gap is the Mac tearing down + re-setting
  up the audio connection and not sending audio meanwhile — **sender/protocol
  side, the Pi can't fill it.** Whether audio resumes perfectly synced after the
  gap is STILL unmeasured (macOS compresses the mirrored audio so the accent
  marker can't be detected; the probe measures pad-arrival not DAC output; and I
  cannot perceive lip-sync). 
- **Bottom line on seek:** the two tractable fixes both failed — sync=true breaks
  live video, and the sender-side audio gap can't be filled on the Pi. Real
  next options: (a) rework UxPlay's live clock handling so sync=true works
  (deep), (b) try UxPlay master/1.74 which has different sync code, (c) find a
  Pi-side way to reset/realign audio on the seek teardown that survives the loop.

## 2026-09-07 (RESOLVED): robust A/V sync incl. seeks — sync=true + qos=false + ts-offset

**The seek problem is fixed.** The winning config (baked into the service, autostart):
`uxplay_debug -vd v4l2h264dec -vc identity -srgb no -n "Living Room TV" -reset 60
-vs "kmssink force-modesetting=true qos=false ts-offset=300000000" -as "alsasink device=plughw:vc4hdmi,0"`
(note: NO `-vsync no`, NO `-vp` frame-delay — sync=true is the default.)

How it was found (all via the faithful replay harness, autonomously):
- **sync=true** (timestamp A/V sync, the UxPlay default) is the RIGHT model — it
  auto-resyncs after a seek (both streams keyed to content ntp), unlike the fixed
  frame-delay hack which provably broke on seek. The earlier belief that
  "sync=true breaks live video" was really the next point:
- **kmssink `qos=false` is essential.** With QoS on (default), kmssink DROPS
  frames whose pts is late — and under network jitter / right after a seek /
  reconnect the frames ARE late → it drops them → video freezes / doesn't appear.
  Reproduced autonomously by feeding the replay video a constant 500ms late
  (`UX_VDELAY_MS=500`): QoS-on → video frozen + "QoS"/dropped log lines; `qos=false`
  → flash markers every 2s throughout (renders late frames instead of dropping).
- **`ts-offset=300000000` (delay video 300ms)** trims the residual audio-behind
  (the audio pipeline's ALSA latency that sync's per-pipeline compensation
  doesn't fully cover). User confirmed **"идеальный синк"** incl. after seeks at 300ms.
  Tunable via `uxrun <ms>` (survives seeks, unlike the old frame delay).
- The harness fix that made faithful autonomous testing possible: `replay_feeder`
  now calls the real `video_process`/`audio_process` (so `remote_clock_offset` +
  the pts-mismatch loop run exactly as live), and `video_renderer_choose_codec(false,false)`
  is called in `replay_run` (selects the h264 renderer + PLAYING — else `renderer`
  stays NULL). `UX_VDELAY_MS` env injects simulated video jitter.

**Reconnect/seek bugs — root-caused from logs + core dump, fixed:**
- **Audio "flew off":** `audio_renderer_render_buffer` DROPPED every buffer when
  `ntp < gst_audio_pipeline_base_time` (a clock jump on seek/reconnect) →
  hundreds of `*** invalid ntp_time < base_time` in the log → no audio. Fixed:
  re-base (`gst_audio_pipeline_base_time = pts; pts = 0`) and keep playing instead
  of dropping (renderers/audio_renderer.c).
- **Video didn't attach on reconnect:** `video_renderer_choose_codec` returned -1
  (`else if (renderer) return -1`) when the global `renderer` held a stale pointer
  from the previous session → log `*** ERROR: failed to set video codec as H264`.
- **SEGV on rapid reconnect (core dump):** `bt` → `video_renderer_choose_codec`;
  `x/i $pc` → `ldr x0,[x0,#8]` with x0=0. My first attempt (adding `renderer=NULL`
  in `video_renderer_init`, main thread) RACED the RAOP mirror thread's
  `renderer = renderer_used; … renderer->pipeline` → global `renderer` NULLed
  between store and deref → NULL deref. Reverted that. Proper fix: rewrote
  `video_renderer_choose_codec` to (a) guard `renderer_used`/`->pipeline` for NULL
  (soft `return -1`, no `g_error`/abort), (b) operate on the LOCAL `renderer_used`
  throughout, (c) publish the global `renderer` LAST, (d) re-select on reconnect
  instead of returning -1. Fixes both the no-attach and the crash.
- **Don't run `uxrun` (manual) alongside the service** — two instances both
  register the mDNS name "Living Room TV" → `kDNSServiceErr_NameConflict`, which
  also disturbs reconnect. Use the service; `uxrun` is for tuning only (stop the
  service first).
- Core dumps: `LimitCORE=infinity`, `core_pattern=core` → written to
  `WorkingDirectory` `/home/uxplay/core`; `gdb` IS on the Pi. `bt` / `x/i $pc` /
  `info registers` on `/home/uxplay/core` gives the crash site. (180MB each —
  delete after.)

## Superseded open items (kept for history)
1. **Constant A/V offset fine-tuning (in progress, user driving).** With the
   fast path, `-vsync no` gives a *stable, non-growing* offset (picture ahead of
   sound). Tuning knobs and their gotchas (all tested this session):
   - `-vsync <ms>` (range ±1000) enables sync + delays audio by that many ms, but
     it also flips the video sink to `sync=true` while the **audio sink stays
     `sync=false`** → in testing this reintroduced a *growing* desync. If the
     user's tuning drifts, that's why; `-vsync no` is the safe fallback.
   - Audio **cannot be advanced far** (small buffer): `-vsync -700` killed audio
     entirely.
   - **Do NOT use kmssink `ts-offset`** to delay video — it broke sync (audio
     fell seconds behind). Confirmed dead end.
   - A proper fix likely needs a source change: make the audio sink `sync=true`
     (so both sinks share the clock) and/or replace the unbounded video `queue`
     (source patch #3) with a bounded **leaky=downstream** queue so video can't
     accumulate latency. Not yet attempted.
   - User is dialing in the value themselves via `uxrun -vsync <x>`. Once chosen,
     bake final args into `/etc/systemd/system/uxplay.service` (currently still
     the OLD broken args: `-bt709 -reset 60 -vsync no -vs kmssink ...`).
2. Colour accuracy with `-srgb no` (no bt709→sRGB correction) not yet judged by
   eye; revisit only if colours look off once sync is settled.
3. `-mp4` recording feature doesn't currently work in this minimal build
   (missing `aacparse` plugin for the muxer) — not needed for core mirroring,
   skip unless recording is specifically wanted later.
4. Corporate/managed Mac's firewall ("Block all incoming connections") blocks
   AirPlay outright and cannot be disabled (MDM-managed) — always test from
   the **personal** Mac, never the work one.

## Useful one-off diagnostic commands
```bash
# SSH (password auth, no key set up)
sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.1.34 "..."
# (export SSHPASS=pizza first)

# Check power/throttling (always check first for any performance issue)
vcgencmd get_throttled   # 0x0 = healthy
vcgencmd measure_clock arm

# Real-time uxplay diagnostics (bypasses journald rate-limiting)
tail -f /var/log/uxplay.log

# DRM plane/compositing state
cat /sys/kernel/debug/dri/0/state | grep -A10 'plane\['
modetest -M vc4 -p | less   # full property dump incl. zpos/alpha/type per plane
```

## 2026-09-11: `force-modesetting=true` causes a ~750ms-per-frame stall for
## non-native-resolution content; removed. `-nohold` added (stale-connection
## rejection). Real-session `.cap` files are now a regression corpus.

**Symptom:** mirroring from one specific Mac (older AirPlay client, sends a
non-16:9 pixel-aspect-ratio that kmssink scales to an odd resolution, e.g.
1662x1080 instead of native 1920x1080) showed video freeze at 1 frame, or —
after a reconnect — a burst of skipped/rushed frames. A *different* Mac
(newer AirPlay client, sends content that already matches the display's
native mode) mirrored perfectly. Audio was unaffected once real content was
actually playing (a `-nohold` bug, see below, had been masking this as an
"audio never works" issue for hours — don't conflate connection-rejection
symptoms with codec/protocol ones again).

**Root cause, proven with byte-exact evidence (`GST_DEBUG=v4l2videodec:5,v4l2bufferpool:5`):**
the decoder's *capture* (decoded-frame output) buffer pool has only 3 buffers.
Tracing `mark buffer N outstanding` / `mark buffer N not outstanding` showed
each buffer held for a **constant ~745-775ms** before being released back —
v4l2h264dec re-acquires the just-freed buffer within ~20ms every time, so it
is never actually input-starved; something downstream just takes ~750ms per
frame to let go of each buffer. `kmssink sync=false` (a live test) changed
**nothing** — ruling out clock/PTS-deadline waiting entirely. The remaining
suspect was `force-modesetting=true`, which forces kmssink onto the primary
plane via a real DRM modeset (see 2026-09-06 entry above, where this flag was
*added* to fix a slow ~15fps overlay-plane issue for normal 16:9 content) —
for this odd non-native resolution, whatever kmssink/DRM does per-frame under
`force-modesetting` is apparently the ~750ms cost. **Removing the flag** took
the real captured session from 2/153 render/decode events (nearly frozen) to
941/944 in the offline `-replay` harness — confirmed no regression on the
*original* 2026-09-06 problem by also replaying a synthetic 1920x1080 capture:
732/737 render/decode events, still smooth. Both `provisioning/files/etc/systemd/
system/uxplay.service` and `uxrun` updated to drop `force-modesetting=true`.
If the old slow-overlay-plane bug ever reappears for some other resolution,
re-test with `force-modesetting=true` restored and compare `-replay` render
counts before assuming it's still needed — don't just re-add it blind.

**Separate real bug, also fixed:** `raop.c`'s single-client enforcement
(`http_response_init(*response, protocol, 409, "Conflict: Server is connected
to another client")`) has no timeout/cleanup for a connection object that the
client itself abandoned without a clean TEARDOWN — a stale registration can
silently reject every subsequent real connection attempt (including from a
different device) with 409, which a client's own AirPlay stack reports as
`FP-Setup failed: Conflict` / `Stage 1 failed` at the very start, before any
audio/video negotiation even begins. Added `-nohold` (an existing UxPlay flag,
"drop current connection when new client connects") to the systemd unit —
correct fit for a single dedicated-receiver appliance, where whoever is
currently trying to mirror should always win.

**`-nohold` reverted the same day -- wrong fix, real UX regression.** Live
dual-client test (deliberately started mirroring from a second Mac while the
first was actively mirroring) showed `-nohold` doing exactly what it says:
silently dropping the ACTIVE session's connection mid-stream to let the new
one in, and the new one itself needed two connection attempts before actually
working. User's explicit expectation, confirmed correct: a single-appliance
receiver should **refuse** (or go quiet on) a second client while genuinely
in active use, not silently evict the current one -- which is what the code
already did before `-nohold` (the 409 "Conflict" rejection). The actual bug
was narrower: a connection the *client itself* abandoned without a clean
TEARDOWN could stay registered and keep rejecting new attempts past the point
it reasonably should. That already has a built-in recovery: `-reset 60`
resets the whole HTTP daemon (`raop_stop_httpd` + `raop_remove_known_
connections`, uxplay.cpp's `relaunch_video`/`reset_httpd` path) after 60s of
missed client feedback, clearing any stale registration -- verified by
reading the code path, not yet empirically re-confirmed live (couldn't be,
via `-replay`: this is httpd/connection-registry behavior, entirely outside
what the replay harness's video/audio frame feeder exercises). If a stale
connection is ever observed blocking new connections for longer than ~60s,
that's the next real bug to chase -- not another blunt "always let the
newest connection win" flag.

**Methodology note for next time:** don't ask the user to re-trigger a live
AirPlay session per hypothesis. Record one real session via `-capture`
(already-existing harness, see 2026-09-06 entry) once, then iterate entirely
via `-replay` + `GST_DEBUG` on the Pi. `tools/captures/` now holds real
captured sessions (gitignored via `*.cap`, kept locally) — treat them as a
growing regression corpus, not disposable debugging scratch: replay every one
of them after any future `kmssink`/`v4l2h264dec` pipeline change, the same
way `tools/test-reconnect-e2e.sh` already replays the reconnect-path capture.

## 2026-09-12: boot-console text visible in pillarbox margins; fixed with two
real bugs found (and fixed) along the way

Real bug, not the aspect-ratio "bug" reported alongside it: a MacBook Pro's
actual screen ratio (Mac14,9, 1662x1080 native decode caps, ratio ≈1.539) is
genuinely not 16:9, confirmed via the decoder's negotiated caps, so pillarboxing
on a 1920x1080 TV is correct behavior, not a bug — the real complaint was that
the *margins* showed the kernel's boot console text instead of solid black.
Root cause: kmssink's main pipeline draws onto a DRM **overlay** plane sized
only to the content's actual dimensions (e.g. 1662x1080), not the full
1920x1080 screen (see the `force-modesetting` removal above, 2026-09-11) — the
**primary** plane underneath, still showing whatever the boot console last
drew there, is never repainted, so it stays visible in whatever area the
overlay plane doesn't cover, for however long the device has been up.

Fixed with a new `video_renderer_blank_display_now()`, called once at process
startup, reusing the existing "paint one black frame onto the primary plane
via `force-modesetting` kmssink, then release" mechanism already used for the
frozen-last-frame-after-disconnect fix (2026-09-10).

**Two real bugs found while placing the call, both confirmed on real hardware
rather than assumed — exactly the "verify positively, not just no-regression"
methodology corrected earlier this session:**

1. Calling it right after `video_renderer_start()` segfaulted. `logger` is a
   module-level global in `video_renderer.c`, only set inside
   `video_renderer_init()` — and the new call ran before `video_renderer_init()`
   had ever been called (this was the very first `video_renderer_*` call in
   the process). Confirmed via `gdb`: `SIGSEGV` in `pthread_mutex_lock()`,
   called from `logger_log()`, called from `video_renderer_blank_display()`.
2. Moving the call to strictly between `video_renderer_init()` and
   `video_renderer_start()` (so `logger` is valid) fixed the crash but hit a
   *second* real bug: a DRM-master conflict. `video_renderer_init()` itself
   already drives the h264 pipeline's kmssink far enough to claim its overlay
   plane — confirmed in the `GST_DEBUG` log, `kmssink_h264 ... connector id =
   35 / crtc id = 97 / plane id = 98` appearing well before
   `video_renderer_start()` ever runs. With that plane already claimed, the
   blank pipeline's own `force-modesetting` grab for the primary plane failed:
   `kmssink gstkmssink.c:805:configure_mode_setting: Failed to set mode:
   Permission denied`.

Final fix: call `video_renderer_blank_display_now()` strictly *before*
`video_renderer_init()`, and give it the logger as an explicit parameter
(setting the module's `logger` global itself) instead of depending on
`video_renderer_init()` having already set it. Verified clean on real
hardware: correct plane-claim ordering (blank pipeline claims plane 86 and
fully releases it before the real h264 pipeline ever touches plane 98), zero
permission errors, no crash. Replayed against the real stalled-mirror capture
(`tools/captures/personalmac-stall-20260911.cap`): 99% render/decode ratio
(1864/1866), matching the existing healthy baseline — no regression.

**Visual/pixel-level self-verification remains an open tooling gap.** Two
independent attempts to read the actual DRM scanout content without asking
the user to look at the TV, both genuine dead ends:
- `ffmpeg -f kmsgrab` — every tried pixel format (`bgr0`, `0rgb`, `rgb0`,
  `0bgr`, `argb`, `abgr`, `rgba`, `bgra`) failed with "Invalid output format
  for hwframe download", eventually "Function not implemented". Plane 86's
  reported DRM format code doesn't decode to a valid ASCII fourcc — looks like
  a real vc4/mesa driver quirk, not a flag/naming problem.
- Direct `/dev/fb0` read (`vc4drmfb`, confirmed present via `dmesg`, 1920x1080
  @16bpp) — byte-identical content sampled before and after the blank pipeline
  ran and fully released. This buffer is evidently a separate, decoupled
  fbdev-emulation buffer, not a live mirror of the actual DRM scanout —
  reading it proves nothing about what's really on screen.
No compiler exists on the live Pi to build a custom capture tool in place;
cross-building one via the project's existing Docker/arm64 build
infrastructure (same shape as how `uxplay_debug` itself is built) remains a
real, not-yet-attempted option if this gap needs closing for good. For now,
confidence rests on: the identical mechanism already being proven to work in
production for the disconnect/frozen-frame case, a clean startup log with the
correct plane-claim ordering, and a clean `-replay` regression run — not on
an actual look at the screen.

## 2026-09-12 (correction): the above fix DID NOT actually work; real fix found
via a new pixel-level scanout tool

**The tooling gap above is now closed.** `tools/drmdump.c` +
`Dockerfile.drmdump-buildtest`: a small libdrm-based tool, cross-built the
same way as `uxplay_debug`, that reads each DRM plane's real content straight
from its dumb-buffer framebuffer via the atomic/universal-planes API
(`drmModeGetPlane()->fb_id`, not the legacy per-CRTC `buffer_id`, which does
**not** reliably track atomic commits on this driver — confirmed empirically:
it kept reporting the same fb id across a plane update that the kmssink log
showed had genuinely happened). Paired with `ffmpeg -f rawvideo` to convert
the raw dump to a viewable PNG. This finally gives real, positive,
pixel-level self-verification of what's actually on screen, closing the gap
documented above (`ffmpeg kmsgrab` and a naive `/dev/fb0` read were both
dead ends).

**Using it immediately disproved the previous "fix."** The startup
`video_renderer_blank_display_now()` call did run, and did briefly paint a
real black frame on the primary plane (confirmed in the log: a new fb id
appears) — but a scanout dump taken a few seconds later, once the pipeline
had released DRM master, showed the boot console text, byte-for-byte
unchanged from before the "fix" ran. **Root cause of the previous
misdiagnosis:** the earlier `/dev/fb0` read that seemed to show "no change"
(previous entry above) was tested at exactly the wrong moment — before vs.
after a full paint-then-revert cycle, which of course looks identical either
way. That test proved nothing; it wasn't evidence `/dev/fb0` is decoupled
from the scanout, it just happened to compare two points where nothing had
net-changed.

**Actual mechanism**: the kernel's own fbcon owns `/dev/fb0` as a persistent
buffer and reasserts its content back onto the DRM primary plane whenever no
other client holds DRM master over that plane — including immediately after
the throwaway blank pipeline releases it. Painting a transient frame can
never win against this; the buffer itself has to be changed.

**Real fix** (submodule commit reverting 85094e1; main repo commit
`5d284ec`): a new `provisioning/files/usr/local/bin/zero-fb0` script,
run via `ExecStartPre=` in `uxplay.service` before uxplay ever touches DRM.
Reads the real geometry from `/sys/class/graphics/fb0/{virtual_size,
bits_per_pixel}` and zeros exactly that many bytes. No UxPlay code needed at
all — this was never a code bug, it was a leftover-state problem better
solved at the provisioning layer.

**Verified with actual pixel evidence, three separate checks**, each
converted from a real scanout dump to PNG and visually confirmed solid
black: (1) immediately after running the script, before uxplay starts; (2)
after uxplay's pipelines start and settle into idle, waiting for a client;
(3) mid-way through a real `-replay` session, with real video actively
rendering on the overlay plane at the same time — the primary plane stayed
black underneath throughout. No render/decode regression: 1961/1965 (99.8%),
matching the existing healthy baseline.

**Open follow-up, not yet checked**: the disconnect-time frozen-last-frame
fix (2026-09-10, commit 5a84a7e) uses this exact same "throwaway
force-modesetting blank pipeline" mechanism, just triggered on teardown
instead of at startup. Given what was just found, it likely suffers the
same "paints black, then fbcon reasserts" failure — worth re-verifying with
this same drmdump tool before trusting it. Two things work in its favor that
don't apply to the margins bug: `/dev/fb0` being permanently zeroed now
means fbcon's own reassertion is harmless from now on (it restores black,
not stale content), and the actual frozen-frame concern was about the
**overlay** plane (the one real video renders onto), not the primary plane
this mechanism targets — whether tearing down the main pipeline cleanly
disables/hides the overlay plane on its own (independent of the blank
pipeline entirely) has not been empirically confirmed. Next step if this is
revisited: dump plane state right after a real disconnect and check the
overlay plane's `fb_id` actually goes to 0 / the plane is removed from the
composition.

## 2026-09-12: configurable overscan compensation, tunable live without
dropping the connection — new standing product requirement

The TV crops a small margin off all four edges via its own internal
overscan/zoom scaling, confirmed with a new pixel-ruler calibration tool
(see below) plus a real photo of the TV: roughly left≈8px, right≈28px,
top≈5px, bottom≈0px (under ~1.5% per edge; real uncertainty from a single
angled photo — the left/right asymmetry is more likely a perspective
artifact than a genuine asymmetric crop). This TV has no "Just Scan"/"1:1
Pixel Mapping" setting, so there's no TV-side fix. **Standing product
requirement going forward**: the Pi must compensate for overscan itself,
tunable by the user, without stopping an active mirroring session.

**New calibration tooling** (`tools/drmdump.c`, `tools/drmpaint.c`,
`Dockerfile.drmdump-buildtest`, cross-built the same way as `uxplay_debug`):
- `drmpaint`: paints a pixel-accurate concentric black/white ruler pattern
  (10px bands, colored reference lines at 50/150/150px — though the 1px-wide
  color lines turned out too thin to survive TV scaling + photo compression;
  future version should use thicker color bands) directly onto the DRM
  primary plane via a dumb buffer, held for a configurable duration. Used to
  get one real photo of the TV showing a known pattern.
- `drmdump`: reads real DRM plane content and geometry. Extended twice this
  session: (1) `drmModeGetFB2` + PRIME export for multi-planar/modifier
  framebuffers (real decoded video is YUV420/YU12, which the simple
  dumb-buffer path can't read — `drmModeGetFB` fails EINVAL on these); (2)
  atomic `CRTC_X`/`CRTC_Y`/`CRTC_W`/`CRTC_H` plane properties (needs
  `DRM_CLIENT_CAP_ATOMIC`, not just `DRM_CLIENT_CAP_UNIVERSAL_PLANES` —
  these aren't exposed to a non-atomic client at all) — this is the actual
  on-screen destination rectangle a plane is composited into, which is
  *not* the same as the decoded buffer's own native dimensions (confirmed:
  the buffer stays 1662x1080 — the source's native decode size — regardless
  of `render-rectangle`; only these 4 properties change).
- The photo was measured programmatically: locate the bezel edge and the
  point where the ruler pattern flattens into solid gray, solve against the
  known 200px reference distance. See git history for the exact script.

**Mechanism**: `kmssink`'s `render-rectangle` property (a plain GObject
property) fits/letterboxes its output inside an inset sub-rectangle instead
of the full 1920x1080; the margin renders solid black because the DRM
primary plane underneath is kept zeroed (`zero-fb0`, 2026-09-12 fix above).
Confirmed via `drmdump`'s new atomic-property reading that kmssink does
correct aspect-preserving fit-and-center *within* that inset box (verified
the exact expected math: for a 1920x1870-inset-to-1638-wide fit of 1662x1080
source content, centered, `CRTC_X`/`CRTC_W` matched the hand-computed
values exactly).

**Live tuning, without dropping the connection**: this needed real code
changes, not just a provisioning script — only the process holding the live
kmssink elements can change this property without a pipeline rebuild.
- `UxPlay/renderers/video_renderer.c`: new `video_renderer_apply_overscan()`
  reads `/etc/default/uxplay` (`UXPLAY_OVERSCAN_{LEFT,RIGHT,TOP,BOTTOM}`,
  pixels, all default 0), validates, and applies the rectangle to every live
  named kmssink element (`gst_bin_get_by_name`, `"<sink>_<codec>"`, e.g.
  `"kmssink_h264"`) via `gst_util_set_object_arg` — reusing the exact
  string syntax already proven to work live earlier this session, rather
  than hand-building a `GValueArray`.
- `UxPlay/uxplay.cpp`: calls it once at startup (right after
  `video_renderer_start()`), and registers a `GFileMonitor` on the config
  file inside `main_loop()` for later live edits.
- **First live-reload trigger design (SIGHUP) was wrong** — confirmed via
  `grep`: SIGHUP is already claimed in this exact file, mapped to the same
  graceful-shutdown handler as SIGINT. User's explicit choice: fully
  automatic (inotify via `GFileMonitor`), not a manual `systemctl reload`
  signal — implemented instead.
- **First test methodology was wrong, caught before shipping**: tested the
  live-reload exclusively via `-replay`, which uses its own separate
  `replay_loop`/loop function and never reaches `main_loop()` at all — so
  the file-monitor code path was silently never exercised, even though the
  test "looked" like it passed (one edit's value happened to appear in the
  log, purely because the *startup* apply's own ~5s kmssink init latency
  raced past the edit and read the post-edit file — not because live-reload
  fired). Caught by re-running with clean timing separation between the
  startup window and the edit. **Live reload can only be tested against the
  real daemon loop** (`main_loop()`, reached in normal operation regardless
  of whether a client is connected — confirmed via `grep -n "main_loop("`,
  called exactly once from `main()`), not via `-replay`.
- Verified correctly once tested against the right loop: `GFileMonitor`
  correctly debounces a `cat > file` overwrite's raw filesystem events
  (`G_FILE_MONITOR_EVENT_CHANGED` ×2) into a single
  `G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT`, which triggers exactly one
  correct re-application of the new values.
- **Not yet confirmed**: a live edit while an actual client is *actively
  mirroring* (real AirPlay session, not `-replay`) — the mechanism should
  be sound (`-replay`'s own render/decode counts kept incrementing
  uninterrupted across an edit in the flawed test above, and the property
  change itself doesn't touch pipeline state), but this specific
  combination hasn't been directly observed yet.

**Provisioning**: new `provisioning/files/etc/default/uxplay` (config,
all-zero default). `provisioning/setup.sh` only installs this file if it
doesn't already exist (must not clobber a hand-tuned config on re-run,
unlike every other provisioned file). Also fixed a real pre-existing gap
found while touching this: `zero-fb0` (2026-09-12 fix above) was deployed
live via ad-hoc SSH commands but was **never added** to either
`provisioning/setup.sh` or `image-builder/customize-root.sh` — a fresh
`make image` or fresh `setup.sh` run would have silently shipped without
it. Fixed in both scripts.

**Verified**: no `-replay` regression (99.8%, matching baseline); startup
apply confirmed via log + `drmdump`'s atomic-property reading (exact
expected geometry math); live reload confirmed via the real daemon loop
with clean timing separation. Deployed live via SSH to the running Pi
(binary + config), not yet baked into a rebuilt image.

**Not done / explicitly deferred**: phase 2 (a real UI for tuning this,
instead of hand-editing the text config) — not started, per the user's own
phasing.

## 2026-09-12 (later): `make image` bakes in WiFi/overscan; image built,
verified, and flashed; interactive SSH was running real dietpi-update

**`personal.env` mechanism** (main repo `61d2d39`): "build an image" used to
mean "build an image, then mount it and hand-edit WiFi creds, then
hand-edit overscan over SSH" — a standing complaint. New optional, gitignored
`personal.env` (template: `personal.env.example`) with `WIFI_SSID`/
`WIFI_PASSWORD`/`OVERSCAN_{LEFT,RIGHT,TOP,BOTTOM}`, read automatically by
`make image` (wired via `$(wildcard personal.env)`) and threaded into
`image-builder/customize-boot.sh` (WiFi → `dietpi-wifi.txt`) and
`customize-root.sh` (overscan → `/etc/default/uxplay`). Absent, the image
is identical to before.

Real bug caught while testing, not assumed: the first WiFi-injection draft
used `sed -i "...c\\..."` to rewrite the credential lines. Sed's own
change/substitute commands treat a backslash in the REPLACEMENT text as an
escape character and consume it — this silently corrupted the
DietPi-documented `'\''` escape for a literal single quote in an
SSID/password, producing `'''` instead. Confirmed empirically inside the
*actual Debian build container* (not assumed from local macOS testing,
whose BSD sed has unrelated `-i`/`c\` quirks of its own that would have
masked this entirely). Fixed by switching to `awk`, whose plain string
printing doesn't reinterpret backslashes; re-verified with SSID/password
values containing single quotes.

Also had to re-pin 3 more aged-out `apt-packages.lock` versions
(`libcurl3t64-gnutls`, `libglib2.0-0t64`, `libmbedcrypto16`) to get a clean
build at all — same recurring drift class as the earlier `libasound2`
re-pin (main repo `9d41f7d`). Check `apt-cache policy <pkg>` inside the
build container whenever `make image` fails with "Version ... was not
found".

**Verified on the actual assembled `.img`, not just the build log**:
re-extracted the built image's own partitions and confirmed both the real
WiFi credentials and the user's actual live-tuned overscan values
(16/16/16/16 — pulled from the Pi's live `/etc/default/uxplay` rather than
the earlier rough photo-based estimate) landed correctly.

**Image built and flashed** (confirmed physical action, not simulated):
`build/rpi-airplay.img` (~1.2GB) written to the SD card via `dd`, following
README's documented procedure (`diskutil unmountDisk` before and after).

**New bug found on the resulting real first boot, fixed the same session**:
every interactive SSH login was synchronously running the real
`dietpi-update` (and would eventually run `dietpi-software` too) —
DietPi's own `dietpi-firstboot.bash` unconditionally does `echo 0 >
/boot/dietpi/.install_stage` during a genuine hardware first boot,
confirmed via `journalctl` on the actual device. This is *why* an earlier
session's fix (baking `.install_stage=2` into the image at build time,
intended to skip DietPi's redundant first-run software wizard) never
actually worked on real hardware — this project's offline chroot/nspawn
testing never runs `dietpi-firstboot.service` at all, so that fix looked
correct in every test that could be run, while doing nothing on the one
environment that matters. With the stage stuck at 0,
`/etc/bashrc.d/dietpi.bash`'s `dietpi-login` hook runs
`Run_DietPi_First_Run_Setup()` on *every* interactive login (not just
once), synchronously executing `dietpi-update` on the login session itself
— the actual "SSH wastes my time" symptom.

Fixed with a new oneshot systemd unit (`dietpi-skip-firstrun.service`,
`After=dietpi-firstboot.service`) that force-resets `install_stage` back to
2 on every boot — this appliance's setup is fully baked in at image-build
time, there's no interactive software-selection step for a human to ever
run, so there's no reason not to just always force this. Deployed live to
the just-flashed device and verified with a real interactive SSH login:
`.install_stage` reads 2, normal DietPi banner shows immediately, no
`dietpi-update` run, ~1.8s total. Also added to both `provisioning/setup.sh`
(live-Pi path, `systemctl enable --now`) and `image-builder/customize-root.sh`
(offline chroot path, direct symlink enable, same pattern as `uxplay.service`)
so it's baked into the *next* image build, not just this live device
(main repo `3bc7e5b`).

**Open**: the currently-flashed image doesn't have this fix baked in (only
deployed live via SSH after flashing) — the pipeline fix is committed for
the *next* `make image` + reflash, whenever that happens.

## 2026-09-12 (later still): frozen last frame after disconnect, fixed for real

Reported directly: "when screen mirroring ends, the last frame remains —
should show a black screen." This had already been "fixed" once, a long
time before this session (submodule history: `5a84a7e`, tried unconditional
`video_renderer_stop()` on every disconnect, reverted for breaking
re-mirroring entirely — `1992e08`), leaving only an *eventual* blank via the
`-reset N` second client-silence timeout reaching `video_renderer_destroy()`.
Not instant, which is what was actually asked for this time — and the
pipeline genuinely can't be torn down on a plain disconnect (that's exactly
what broke re-mirroring before), so any fix has to work without touching
pipeline state at all.

The mechanism: `kmssink`'s `render-rectangle` is a live-settable GObject
property (already used by the overscan feature above), so shrink/move it on
disconnect and restore it in `video_renderer_choose_codec()` when a new
connection actually starts decoding. Two non-obvious problems, both found by
reading `gst-plugins-bad`'s actual `sys/kms/gstkmssink.c` source rather than
guessing from behavior:

1. Setting the property alone is a no-op for anyone currently looking at the
   screen — `gst_kms_sink_show_frame()` (where the real `drmModeSetPlane`
   commit happens) only runs when kmssink processes a buffer, and with no
   client connected, no new buffer ever arrives. Confirmed empirically via
   `tools/drmdump.c` polling the real DRM plane properties every second
   throughout a simulated disconnect (`UX_RECONNECT_MODE=real` + new
   `UX_RECONNECT_PAUSE_MS` test hook to hold the gap open long enough to
   observe): the on-screen rectangle never moved, no matter what the
   property was set to. Fix: also call `gst_video_overlay_expose()`
   (standard `GstVideoOverlay` interface — confirmed kmssink implements it),
   which re-runs `show_frame()` against the last held buffer, no new buffer
   needed.
2. A first attempt at the "hidden" rectangle, `<0,0,1,1>` (shrink to a
   single pixel), still didn't visibly change anything even with `expose()`
   wired up. `gst_kms_sink_show_frame()` fits the video into the configured
   rectangle via `gst_video_sink_center_rect()` (aspect-preserving), and if
   *either* resulting dimension rounds down to `<= 0` — exactly what happens
   fitting a ~1920x1080 source into a literal 1x1 box — it logs "video is
   out of display range" and skips the DRM commit entirely, leaving
   whatever was already on screen untouched. This silent skip is what every
   earlier "confirmed via log that expose() ran, but drmdump still shows
   the old geometry" observation was actually seeing. Fixed by using a
   full-size rectangle instead (so the aspect-preserving fit is always
   comfortably positive in both dimensions, same as a normal overscan
   rectangle) positioned with a large negative X — the only overflow clamp
   in that function is for the right/bottom edge, never for a negative left
   edge, so the width survives unclamped and the plane just ends up drawn
   somewhere the CRTC can't see it.

**Verified positively, not just "no error in the log"**: `tools/drmdump.c`
polling the real DRM plane's atomic properties once a second across a
simulated real disconnect+reconnect showed the on-screen rectangle go from
the normal position (`CRTC_X=154 CRTC_W=1612`), to fully off-screen at
disconnect (`CRTC_X=-1791 CRTC_W=1662`, i.e. `X+W` still negative), back to
the exact same normal position at reconnect — every single second polled
across three separate runs, including after the final logging/comment
cleanup pass (re-verified against the literal binary being deployed, not
just "should still work"). Also re-ran the existing decoder-wedging
regression suite (`tools/test-reconnect-e2e.sh`) against the fixed binary:
kmssink kept importing new DMA-BUFs at the same rate after reconnect as
before (122→124 render events in the final run) — no regression in the
unrelated bug that suite guards against.

`UX_RECONNECT_PAUSE_MS` (new env var, `replay_do_reconnect()`'s `real`
mode) is permanent test infrastructure now, alongside the existing
`UX_RECONNECT_AT_MS`/`UX_RECONNECT_MODE` — it's what made the drmdump-based
positive verification possible at all, by holding open a gap between
disconnect and reconnect that's normally instantaneous.

Deployed live via SSH to the running Pi (`/usr/local/bin/uxplay_debug`,
checksum-verified against the local build) for immediate relief; not yet
baked into a rebuilt image (submodule `dd95564`, main repo `9163da0`).
