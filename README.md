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
- `docs/` — reference documentation describing only the *current* state
  (threading/locking maps, pipeline construction, test framework, etc. —
  see `docs/README.md` for the index). `docs/bugs/` holds one file per
  fixed/open bug: symptom, root cause, fix, verification — the specific
  counterpart to `PROGRESS.md`'s chronological narrative.
- `Dockerfile` — one shared tooling image for every disposable build/
  test/tool environment this project uses (compiling `uxplay_debug`,
  running unit tests, assembling the Pi image, computing the vendored
  GStreamer closure, building diagnostic tools) — see that file's own
  header. Builds on an Apple Silicon Mac via colima, native, no
  cross-compilation needed.
- `UxPlay/` — git submodule pointing at
  [`dhabensky/UxPlay`](https://github.com/dhabensky/UxPlay), branch
  `dhabensky-dev` (a fork of `FDH2/UxPlay` v1.73.7 with the patches this
  deployment needs — see that repo's history for what and why).
- `tools/capx.c` — parser for the `-capture` file format the UxPlay
  fork's own `-capture`/`-replay` flags write, for inspecting or
  extracting the H.264 elementary stream from a recorded session.
- `Makefile` — the actual build system. `make image` produces a complete,
  ready-to-flash `build/rpi-airplay.img` from a clean checkout; `make
  verify` compares it against a `golden-reference/` capture of the live
  Pi. See "Building and flashing a complete image" below. The raw `.img`
  is the only artifact routine builds produce — no xz compression, since
  every consumer of it (`dd`, the local test harnesses) uses it
  uncompressed; `make image-xz` compresses an already-built image on
  demand for the rare case of actually needing to archive/share one.
- `build/` — gitignored; every build and test artifact lives here, never
  at the repo root. Makefile-tracked products sit directly in `build/`
  (`uxplay_debug`, `rpi-airplay.img`, `dietpi-base.img`,
  `vendor-gstreamer/`); everything else is sorted into `bin/` (diagnostic
  tool binaries), `logs/` (debug/replay/reconnect run logs), `pcaps/`
  (raw packet captures + decode tooling), `images/` (calibration/
  verification screenshots), and `compare/` (`make verify` output).
- `image-builder/` — the offline image-assembly pipeline, self-contained:
  extracts the base DietPi image's partitions to plain directories,
  customizes the root filesystem via `chroot`, rebuilds partition
  images, and assembles the final `.img` — all without loop devices or
  `--privileged` containers (see that dir's scripts for the mechanics).
  `image-builder/files/` is the config-file payload it installs onto the
  image (systemd unit, udev rule, `uxrun`, `zero-fb0`, ...). Every `apt`
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
- `tools/` (besides `capx.c`) — reproducibility tooling
  (`vendor-gstreamer-closure.sh` regenerates `vendor/`,
  `verify-reproducible-build.sh` is a double-build hash check,
  `compare-rebuild.sh` is the `make verify` recipe) plus three scripts for
  the live-Pi-over-SSH path, independent of `image-builder/`'s
  from-scratch image assembly: `pissh` is the multiplexed SSH entry point
  everything else uses (run a command, `-s` a script on stdin, `-p`/`-g`
  to copy a file; every call is bounded by `UXPLAY_SSH_TIMEOUT` seconds so
  a dead link fails instead of hanging, and `-k` forgets the device's host
  key after a reflash), `setup.sh` provisions an already-running Pi in place
  (idempotent, safe to re-run), and `deploy.sh` builds and pushes just the
  `uxplay_debug` binary to a Pi that's already set up — the fast path for
  iterating without a reflash.
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
  (`vcgencmd get_throttled` != `0x0`), easily mistaken for a decode/
  software performance bug. Always check `vcgencmd get_throttled` /
  `measure_clock arm` first for any performance issue.

## Backup channel: direct Ethernet cable

When WiFi or the home network is down, plug an Ethernet cable straight
from the Mac to the Pi. The Pi always holds `169.254.100.1/16` on `eth0`
(`eth0-backup-ip.service`), whether or not the cable was in at boot. The
Mac needs no setup: with no DHCP server on the cable, macOS self-assigns a
`169.254.x.x` address on that interface after a few seconds. Then:

```
ssh -o BindInterface=en9 root@169.254.100.1
```

`en9` is the Mac's wired interface (`ifconfig` — the one with a
`169.254.x.x` address and `status: active`; it depends on the adapter).
`BindInterface` is needed while the Mac's WiFi is up: macOS also installs a
`169.254/16` route on `en0` and prefers it, so a plain
`ssh root@169.254.100.1` goes out over WiFi and times out. With WiFi off the
plain form works. An alternative that never depends on routing is the
Pi's IPv6 link-local address with an explicit interface:
`ssh root@fe80::ba27:ebff:feef:9450%en9` (derived from this Pi's eth0 MAC).

`rpi-airplay.local` also resolves over the cable (mDNSResponder returns
both the WiFi and the cable addresses), but which one `ssh` picks is up to
macOS, so don't rely on it when WiFi is flaky.

This is additive only: WiFi stays the primary path and the Pi runs no DHCP
server, so plugging `eth0` into a real LAN hands out no DHCP leases (avahi
is not restricted to `wlan0`, so it does advertise the host and AirPlay
services there too). The address is link-scope, so the idle menu keeps
showing the WiFi IP. Checked offline by `make test-eth-backup`
(`tools/nspawn-test-eth-backup.sh`).

## Services on the device

Two units own the AirPlay receiver and its screen:

- **`uxplay.service`** — `uxplay_debug` itself, under `log-ts`. Reads
  `/etc/default/uxplay` for the display name only, exposes an overscan
  channel (`-ofifo /run/uxplay/overscan.fifo`) and a session-event channel
  (`-efifo /run/uxplay-events.fifo`, one `session-begin`/`session-end` line
  per transition).
- **`uxplay-menu.service`** — `/usr/local/bin/uxplay-menu`
  (`tools/uxplay-menu.c`), a resident, watchdog-supervised daemon. It
  repaints the idle menu (via `/usr/local/bin/uxplay-menu-render`) when a
  session ends, when `/etc/default/uxplay` changes, and every 5 minutes. It
  is also the only thing that sets uxplay's overscan margins, pushed into
  `-ofifo` at startup, on every edit, and again once uxplay recreates that
  FIFO after a restart. Started by `zero-fb0-late.service`'s `Wants=` (so
  the first paint lands after the boot console has been cleared) and by
  `uxplay.service`'s. It runs as root because the "is a session live?"
  guard needs `ss -tnp` to see process names.

Editing `/etc/default/uxplay` on the device takes the overscan margins and
the menu text live — no restart and no reconnect. `UXPLAY_DISPLAY_NAME` is
the exception: it reaches uxplay as the start-time `-n` argument, so the name
AirPlay advertises stays as it was until `uxplay.service` restarts.

An overscan value that is not an integer leaves that edge at 0, and a
negative one makes uxplay ignore the whole update and use the full screen; no
value in this file can keep `uxplay.service` from starting.

## On-device diagnostics (shipped in the image, nothing to deploy)

- **`/var/log/uxplay.log` lines are timestamped** — UTC ISO-8601 with
  millisecond resolution (`2026-09-22T01:39:45.894 ...`). `uxplay.service`'s
  main process is `/usr/local/bin/log-ts` (`tools/log-ts.c`), which runs
  `uxplay_debug`, timestamps its merged stdout+stderr and exits the way it
  did. One log file, prefixed at the source; consumers grep unanchored
  patterns, so the prefix is transparent to them.
- **`/usr/local/bin/drmdump`** — dumps live DRM plane/CRTC state and writes
  each on-screen plane's framebuffer to `/tmp/drmdump.plane<N>.raw`, or to
  `/tmp/drmdump.plane<N>.p<M>.raw` (one file per buffer) for a multi-buffer
  plane like the video overlay; the way to check what is actually on screen
  (`tools/drmdump.c`).
- **`/usr/local/bin/synthetic-client`** — the standalone test client
  (`UxPlay/tools/synthetic-client.cpp`); drives real RTSP/RTP sessions
  against the running `uxplay.service` (`mirrortest`, `threadtest`, ...).
  See `docs/testing.md`.

These are on-demand tools with no units and no runtime cost. `tcpdump` and
`gdb` are installed too (`apt-packages.lock`).

## Building the uxplay_debug binary

```bash
make uxplay
# or directly: ./tools/build-uxplay.sh build/uxplay_debug
```

Or just run `tools/deploy.sh`, which does the above and copies
the result to a Pi over SSH.

## Building and flashing a complete image

`make image` builds a complete, ready-to-flash `build/rpi-airplay.img`
from a clean checkout — the UxPlay binary, vendored GStreamer runtime, and
a customized DietPi base image, all assembled offline (no loop devices, no
`--privileged` containers; see `image-builder/`).

### 0. Optional: personal settings baked into the image

Copy `personal.env.example` to `personal.env` (gitignored, never committed)
and fill in real values — WiFi credentials and/or overscan compensation —
before running `make image`. Both are entirely optional and independent:
leave a field blank (or skip the file entirely) to get the exact same
image as before, needing the manual steps below instead. `make image`
picks this file up automatically if present; no other step needed.

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

### 4. WiFi — skip this if you set WIFI_SSID/WIFI_PASSWORD in personal.env

Only needed if step 0 was skipped. The image ships with no WiFi
credentials by default (not even in `golden-reference/`, which stores only
a redacted template — see `EXCLUDE-LIST.md`). Before the first real boot,
mount the boot partition (`/dev/disk4s1`, FAT32 — auto-mounts on macOS)
and fill in one entry of `dietpi-wifi.txt`:

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
   allowlist is hand-curated.** `make vendor-gstreamer` computes
   `build/vendor-gstreamer/` fresh, every build, from
   `tools/gstreamer-plugin-allowlist.txt` via
   `tools/vendor-gstreamer-closure.sh` — but which plugins belong on
   that allowlist is still a human judgment call, not derived from
   anything self-evident. Read that file's own comments before adding
   or removing an entry. `tools/setup.sh` (the manual live-Pi path)
   needs a copy of `build/vendor-gstreamer/` transferred alongside it,
   since it never runs Docker itself.
2. **Package installs are frozen against a checked-in apt index, not a
   live mirror — for both the shipped Pi image and the build tooling.**
   `customize-root.sh` installs `apt-packages.lock`'s pins against
   `image-builder/apt-lists/` (captured once by `make refresh-apt-lists`,
   ~11MB of package metadata, no `.deb` binaries); `Dockerfile` installs
   its own tooling packages against the top-level `apt-lists/` (captured
   once by `make refresh-buildenv-apt-lists`, a *different* apt source —
   the plain Debian base image's, not the customized DietPi rootfs's).
   Neither calls `apt-get update` — Debian only publishes the *current*
   version of each package in its live index, so a pinned version (or,
   for the Dockerfile, anything resolved fresh) can vanish the moment
   upstream ships a point/security release, breaking the build for
   reasons that have nothing to do with an intentional change here.
   `apt-packages.lock` and `image-builder/apt-lists/` must be
   regenerated together (see that file's header); the Dockerfile's
   `apt-lists/` has no separate lock file — freezing the index alone is
   sufficient there, since a fresh container with no prior state
   resolves a fixed index deterministically.
   Residual gap either way: this only freezes the *index* — the actual
   `.deb` bytes still come from the live network on a cache miss, and
   `archive.raspberrypi.com`/`dietpi.com/apt` (unlike Debian's own
   mirrors) have no dated-snapshot service at all, so a package sourced
   from either could in principle still disappear from the pool itself,
   not just the index, over a long enough horizon.
3. **The systemd unit's `ExecStart` embeds hand-tuned pipeline flags**
   (`kmssink force-modesetting=true qos=false ts-offset=300000000`,
   `-vd v4l2h264dec -vc identity`) that came from extensive empirical
   tuning documented in `PROGRESS.md`, not from anything self-evident
   in the code — don't "simplify" these without reading that history
   first.
4. **Tier D (an actual flash + boot + AirPlay session) is the only
   remaining unverified step in `REBUILD-STATUS.md`.** Package manifest,
   file-tree content, and binary-exact checks (Tiers A–C) all pass or
   have an explicit, justified accepted delta — read that file's latest
   entry for the current list.
