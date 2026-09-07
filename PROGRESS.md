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
