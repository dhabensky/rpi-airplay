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
- `Makefile` — the actual build system. `make image` produces a complete,
  ready-to-flash `build/rpi-airplay.img` from a clean checkout; `make
  verify` compares it against a `golden-reference/` capture of the live
  Pi. See "Building and flashing a complete image" below. The raw `.img`
  is the only artifact routine builds produce — no xz compression, since
  every consumer of it (`dd`, the local test harnesses) uses it
  uncompressed; `make image-xz` compresses an already-built image on
  demand for the rare case of actually needing to archive/share one.
- `image-builder/` — the offline image-assembly pipeline: extracts the
  base DietPi image's partitions to plain directories, customizes the
  root filesystem via `chroot`, rebuilds partition images, and assembles
  the final `.img` — all without loop devices or `--privileged`
  containers (see that dir's scripts for the mechanics). Every `apt`
  package installed (not just the top-level ones — their full transitive
  closure too) is pinned to an exact version via `apt-packages.lock`, so
  the image doesn't silently drift as Debian trixie moves forward — see
  that file's header for how to regenerate it when a deliberate version
  bump is wanted. A persistent Docker volume caches downloaded `.deb`s
  across builds so re-fetching unchanged packages isn't paid every time.
- `golden-reference/` — captures the live Pi's actual state (package
  list, file-tree content hashes, redacted config) so a rebuilt image can
  be compared against it. `EXCLUDE-LIST.md` documents what's deliberately
  excluded (volatile paths, WiFi PSK — never captured verbatim).
- `tools/` (besides `capx.c`) — reproducibility tooling:
  `vendor-gstreamer-closure.sh` (regenerates `vendor/`),
  `verify-reproducible-build.sh` (double-build hash check),
  `compare-rebuild.sh` (the `make verify` recipe).
- `REBUILD-STATUS.md` — one dated entry per `make verify` run, with every
  Tier A/B/C delta either fixed or explicitly justified. Read the latest
  entry before assuming a build matches the live Pi.

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

## Building and flashing a complete image

`make image` builds a complete, ready-to-flash `build/rpi-airplay.img`
from a clean checkout — the UxPlay binary, vendored GStreamer runtime, and
a customized DietPi base image, all assembled offline (no loop devices, no
`--privileged` containers; see `image-builder/`). The only thing *not*
baked into the image is WiFi credentials — a deliberate, one-time manual
step, same as a stock Raspberry Pi OS/DietPi install.

### 1. Build

```
make image
```

Produces `build/rpi-airplay.img` (~1.1GB, uncompressed — this project
never distributes/downloads this file, only `dd`s it directly, so xz
compression would be pure wasted time on every rebuild; `make image-xz`
compresses one on demand if a build ever actually needs archiving) plus a
`.sha256` sidecar. `make verify` compares the build against the most
recent `golden-reference/` capture and appends a dated entry to
`REBUILD-STATUS.md` — read that file's latest entry for the current,
itemized list of known/accepted deltas before assuming a build is
equivalent to the live Pi.

### 2. Back up the current card first (if you only have one)

```
diskutil list                                 # find the card, e.g. /dev/disk4
diskutil unmountDisk /dev/disk4
sudo dd if=/dev/rdisk4 of=backup.img bs=4m     # whole card is simplest and safest;
                                                # to dump only the used partitions
                                                # instead, find the last partition's
                                                # end via `diskutil info` and pass a
                                                # matching `count=` to dd
```

Then verify the backup before touching the card again: check its size,
sanity-check the partition table (`fdisk backup.img`), and ideally extract
it with `image-builder/extract-partitions.sh` and spot-check a few files.
A backup you haven't verified isn't a real rollback.

### 3. Flash

```
diskutil unmountDisk /dev/disk4
sudo dd if=build/rpi-airplay.img of=/dev/rdisk4 bs=4m
diskutil unmountDisk /dev/disk4          # again, right after — see below
```

On macOS, unmount immediately after the write finishes: macOS auto-mounts
the newly-written FAT32 boot partition, and Finder/Spotlight/`fseventsd`
instantly drop `.Trashes`/`.fseventsd`/`.Spotlight-V100`/`.DS_Store` junk
onto it. This is harmless — DietPi/the RPi bootloader only reads specific
filenames it expects — but don't mistake it for a bad flash if you go
looking at the card's contents afterwards; it'll keep reappearing as long
as the volume stays mounted, so there's no point trying to clean it up.

### 4. WiFi — the one deliberate manual step

The image ships with no WiFi credentials (not even in
`golden-reference/`, which stores only a redacted template — see
`EXCLUDE-LIST.md`). Before the first real boot, mount the boot partition
(`/dev/disk4s1`, FAT32 — auto-mounts on macOS) and fill in one entry of
`dietpi-wifi.txt`:

```
aWIFI_SSID[0]='YourSSID'
aWIFI_KEY[0]='YourPassword'
aWIFI_KEYMGR[0]='WPA-PSK'
```

DietPi consumes this on first boot and configures WiFi automatically.
Alternative: connect Ethernet for the first boot (RPi 3B+ has a built-in
port) and configure WiFi over SSH afterwards instead.

### 4b. Test locally first, without touching the card at all

```
make test-boot
```

Boots the built image's actual root filesystem via `systemd-nspawn` on
colima's own aarch64 Linux VM — no emulation, no card, seconds not minutes.
Checks that `dropbear`/`avahi-daemon`/`uxplay.service` start, and that
`uxplay_debug` gets all the way to trying to open the real V4L2 hardware
decoder before failing (see `tools/nspawn-test-boot.sh`). This is
deliberately as far as local testing can (or should) go: there's no GPU/
KMS display, ALSA HDMI output, or real network adapter in this
environment, so an actual AirPlay session and hardware-decode performance
still require the real Pi — but everything else (package installs,
`/home/uxplay`-style ownership, systemd unit wiring, missing shared
libraries) is now practically catchable before ever touching the SD card.
This exact tool caught a real bug during development: `uxplay_debug`
silently depends on `libplist-2.0.so.4`, which wasn't tracked by any
package install *or* by `vendor/`'s GStreamer closure (that closure only
walks GStreamer plugins' own dependencies, not the main executable's) —
invisible to `make verify`'s Tier A/B, only surfaced by actually trying to
run the binary.

It also separately checks that UxPlay's **software** decode path
(`-avdec`, GStreamer's `avdec_h264`, with `fakesink` standing in for the
missing GPU/ALSA hardware) constructs and starts cleanly — this doesn't
exercise a live AirPlay session (no client connects in this test), but
confirms the decode pipeline itself is sound, not just that the
hardware-only path fails for the expected reason. Real end-to-end AirPlay
testing against the emulator (pointing your actual Mac's mirroring at it)
was considered but requires switching colima's network mode from `shared`
to `bridged` and restarting it — a bigger, whole-Docker-daemon change not
taken on here — so a real client session still needs the actual Pi.

### 5. First boot

DietPi's stock base image ships with a small root partition sized to
auto-expand into whatever card it's flashed onto — expect a filesystem
resize plus one automatic reboot on the very first boot; that's normal,
not a failure. Once that settles and WiFi/Ethernet comes up,
`systemctl status uxplay` should show it running. SSH access is via
dropbear (DietPi's default) with the same root/password auth this project
has always used — see `REBUILD-STATUS.md`'s openssh-vs-dropbear note for
why. See `PROGRESS.md` for functional verification (AirPlay discovery,
A/V sync).

## Known gaps (read before treating this as fully reproducible)

1. **The vendored GStreamer plugin closure is regenerable, but its
   allowlist is hand-curated.** `make vendor-gstreamer` recomputes
   `vendor/gstreamer-1.0-arm64-trixie/` from
   `tools/gstreamer-plugin-allowlist.txt` via
   `tools/vendor-gstreamer-closure.sh` (verified byte-identical against
   the checked-in copy) — but which plugins belong on that allowlist is
   still a human judgment call, not derived from anything self-evident.
   Read that file's own comments before adding or removing an entry.
2. **The systemd unit's `ExecStart` embeds hand-tuned pipeline flags**
   (`kmssink force-modesetting=true qos=false ts-offset=300000000`,
   `-vd v4l2h264dec -vc identity`) that came from extensive empirical
   tuning documented in `PROGRESS.md`, not from anything self-evident
   in the code — don't "simplify" these without reading that history
   first.
3. **Tier D (an actual flash + boot + AirPlay session) is the only
   remaining unverified step in `REBUILD-STATUS.md`.** Package manifest,
   file-tree content, and binary-exact checks (Tiers A–C) all pass or
   have an explicit, justified accepted delta — read that file's latest
   entry for the current list.
