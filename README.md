# rpi-airplay

A Raspberry Pi 3B+ configured as a dedicated AirPlay screen-mirroring
receiver, plugged into a TV's HDMI input: a MacBook mirrors its screen
(video playback included) and the Pi renders it with the display's
hardware H.264 decoder, in sync with audio, over a headless
kmssink + v4l2 + ALSA pipeline (no X11/Wayland).

Latency doesn't matter for this use case; audio/video sync — including
surviving seeks — does.

## Repo layout

- `PROGRESS.md` — narrative debugging/decision log for the whole project
  (start here to understand *why* things are the way they are; this
  README covers *what* and *how to reproduce*).
- `Dockerfile.uxplay-buildtest` — builds the `uxplay` binary for arm64
  Linux (build on an Apple Silicon Mac via colima, native, no
  cross-compilation needed).
- `UxPlay/` — git submodule pointing at
  [`dhabensky/UxPlay`](https://github.com/dhabensky/UxPlay), branch
  `dhabensky-dev` (a fork of `FDH2/UxPlay` v1.73.7 with the patches this
  deployment needs — see that repo's history for what and why).
- `provisioning/` — scripts + config files to take a fresh DietPi install
  to a working uxplay receiver, and to build+deploy the binary.
- `vendor/gstreamer-1.0-arm64-trixie/` — vendored GStreamer runtime
  plugins the Pi needs that aren't (yet) built from a scripted recipe —
  see that directory's `MANIFEST.md`, this is the project's main
  reproducibility gap right now.
- `tools/capx.c` — parser for the `-capture` file format the UxPlay fork
  writes (see `provisioning`/UxPlay's own `-capture`/`-replay` flags),
  for inspecting or extracting the H.264 elementary stream from a
  recorded session.

## Hardware / network facts

- Raspberry Pi 3 Model B+, 2GB SD card
- Base OS: DietPi (Debian 13 "trixie", arm64), heavily trimmed
- Joins the home WiFi as a normal client (not a standalone hotspot — the
  Mac needs simultaneous internet access)
- ALSA HDMI audio device: `hw:vc4hdmi,0` (single HDMI port on the 3B+)
- **Power supply matters**: an underpowered PSU causes ARM throttling
  (`vcgencmd get_throttled` != `0x0`) which was previously misdiagnosed
  as a decode/software performance bug. Always check
  `vcgencmd get_throttled` / `measure_clock arm` first for any
  performance issue.

## Building the uxplay_debug binary

```bash
docker build -t uxplay-buildtest -f Dockerfile.uxplay-buildtest .
id=$(docker create uxplay-buildtest)
docker cp "$id:/usr/local/bin/uxplay" ./uxplay_debug
docker rm "$id"
```

Or just run `provisioning/deploy.sh`, which does the above and copies
the result to a Pi over SSH.

## Setting up a Pi from a fresh DietPi install

1. Flash DietPi (Debian 13 trixie, arm64), enable SSH, join it to WiFi.
2. `apt install avahi-daemon` is handled by `provisioning/setup.sh`, along
   with everything else that's system config rather than the uxplay
   binary itself — see that script.
3. Copy this repo (or at least `provisioning/`, `vendor/`,
   `Dockerfile.uxplay-buildtest`) to the Pi, or run `setup.sh` against it
   remotely.
4. `sudo ./provisioning/setup.sh`
5. Build and deploy the binary (see above / `provisioning/deploy.sh`).
6. `systemctl start uxplay`

See `provisioning/setup.sh`'s own comments and `vendor/.../MANIFEST.md`
for what's still a manual/vendored step rather than a from-source build.

## Known gaps (read before treating this as fully reproducible)

1. **The GStreamer plugin runtime is vendored, not built from a script.**
   See `vendor/gstreamer-1.0-arm64-trixie/MANIFEST.md` — this is the
   biggest reproducibility risk in the project right now.
2. **No scripted base image build.** `provisioning/setup.sh` assumes a
   DietPi image already exists and is reachable over SSH; there's no
   recipe here for producing that base image from scratch (partition
   layout, DietPi first-boot config, WiFi credentials, SSH key
   provisioning). A full custom `.img` was produced once during
   development but is not checked in here (1GB+ binary, and it embeds
   this network's WiFi credentials) — treat the base OS as "DietPi
   default install, then run setup.sh", not as a single golden image.
3. **The systemd unit's `ExecStart` embeds hand-tuned pipeline flags**
   (`kmssink force-modesetting=true qos=false ts-offset=300000000`,
   `-vd v4l2h264dec -vc identity`) that came from extensive empirical
   tuning documented in `PROGRESS.md`, not from anything self-evident
   in the code — don't "simplify" these without reading that history
   first.
4. **Backups (`.bak`) and ad-hoc test artifacts accumulate directly on
   the Pi's filesystem** (e.g. `/usr/local/bin/uxplay_debug.bak*`,
   `/etc/systemd/system/uxplay.service.bak`, capture files under `/tmp`)
   from iterative debugging sessions over SSH — these are not tracked
   anywhere and should be cleaned up / not relied upon.
