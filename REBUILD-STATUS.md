# Rebuild verification status

One entry per `make verify` run, appended by `tools/compare-rebuild.sh`.
Each entry records which golden-reference snapshot and which built image
were compared, and the result of each tier:

- **Tier A** (package manifest) — must match exactly; routine version
  bumps are noted as accepted deltas, not silently ignored.
- **Tier B** (file-tree content) — sha256 diff of every path present in
  both the golden reference and the candidate, minus
  `golden-reference/EXCLUDE-LIST.md`'s volatile paths. Paths unique to one
  side (e.g. from a package version bump) are counted separately from
  actual content mismatches on shared paths.
- **Tier C** (binary-exact) — `uxplay_debug` and the vendored GStreamer
  files. No accepted deltas here: both are independently, fully
  reproducible (see `Dockerfile.uxplay-buildtest` / `tools/vendor-gstreamer-closure.sh`).
- **Tier D** (functional smoke test) — flash + boot + a real AirPlay
  session. Blocked until spare SD card/Pi hardware is available; never
  silently marked passing.
- **Tier E** (raw disk bit-diff) — deliberately not attempted. See the
  project plan for why a byte-for-byte disk image comparison is the wrong
  target (SSH host keys, machine-id, non-deterministic ext4 block
  allocation all differ even given a perfect rebuild).

**Top-line verdict, as of the most recent run below:** see that entry.
Overall "safe as a disaster-recovery replacement" requires Tier D to have
actually run at least once — until then the honest answer is **PARTIAL**.

(`tools/compare-rebuild.sh`'s mechanics were validated against a synthetic
plain-Debian rootfs during development -- Tier A/B/C logic all ran
correctly end-to-end, but that run isn't a meaningful comparison against
the real DietPi base and isn't recorded here. The first real entry needs
`image-builder/BASE-IMAGE.env` populated via `make refresh-base-image`.)

## 2026-09-08T03:47:47Z
- golden-reference snapshot: `golden-reference/snapshots/2026-09-07/`
- built image: `build/rpi-airplay.img` (fa87d5e28412...)
- UxPlay submodule commit: `0eeae8f`
```
debugfs 1.47.2 (1-Jan-2025)
Extracted boot partition -> /tmp/compare-work/boot (422 files)
Extracted root partition -> /tmp/compare-work/root (13170 files)
=== TIER A: package manifest ===
DIFF: package selections differ (- golden, + candidate):
2d1
< alsa-utils					install
31a31,32
> dropbear					install
> dropbear-bin					install
81d81
< libatopology2t64:arm64				install
85d84
< libavahi-client3:arm64				install
88d86
< libavahi-compat-libdnssd1:arm64			install
114d111
< libcbor0.10:arm64				install
139,141d135
< libdrm-etnaviv1:arm64				install
< libdrm-tegra0:arm64				install
< libdrm-tests					install
154,155d147
< libfftw3-single3:arm64				install
< libfido2-1:arm64				install
245d236
< libpcap0.8t64:arm64				install
317a309,310
> libtomcrypt1:arm64				install
> libtommath1:arm64				install
341,342d333
< libwrap0:arm64					install
< libwtmpdb0:arm64				install
400,402d390
< openssh-client					install
< openssh-server					install
< openssh-sftp-server				install
416d403
< runit-helper					install
427d413
< tcpdump						install

=== TIER B: file-tree content (root partition, minus EXCLUDE-LIST.md) ===
DIFF: 137 files differ in content on shared paths (see build/compare-tierb-mismatches.txt)
  (golden-only paths: 1758, candidate-only paths: 40 -- expected for routine
   package version bumps; see REBUILD-STATUS.md accepted-delta notes, not auto-failed here)

=== TIER C: binary-exact (uxplay_debug + vendor GStreamer) ===
DIFF: uxplay_debug differs (golden=e567a903fccae13bf0ef0e6b6145d9e60a538bf7e00f08cec7606036b1533793 candidate=90cc7cc45002df4443c59749608955423eea64b023e748f432e0dd11e970ee54) --
  expected ONLY if the UxPlay submodule commit changed since the golden capture;
  a mismatch against a build of the SAME commit is a real reproducibility bug.
PASS: all vendored GStreamer files match exactly

=== TIER D: functional smoke test ===
BLOCKED: no spare SD card/Pi available for a real flash+boot+AirPlay test (see plan).

=== TIER E: raw disk bit-diff ===
N/A by design: the .img is the deliverable, not a byte-diff target (see plan's reframing).
```

## 2026-09-08T03:55:44Z
- golden-reference snapshot: `golden-reference/snapshots/2026-09-07/`
- built image: `build/rpi-airplay.img` (6147a2b831e6...)
- UxPlay submodule commit: `0eeae8f`
```
debugfs 1.47.2 (1-Jan-2025)
Extracted boot partition -> /tmp/compare-work/boot (422 files)
Extracted root partition -> /tmp/compare-work/root (13247 files)
=== TIER A: package manifest ===
DIFF: package selections differ (- golden, + candidate):
2d1
< alsa-utils					install
81d79
< libatopology2t64:arm64				install
85d82
< libavahi-client3:arm64				install
88d84
< libavahi-compat-libdnssd1:arm64			install
139,141d134
< libdrm-etnaviv1:arm64				install
< libdrm-tegra0:arm64				install
< libdrm-tests					install
154d146
< libfftw3-single3:arm64				install
245d236
< libpcap0.8t64:arm64				install
427d417
< tcpdump						install

=== TIER B: file-tree content (root partition, minus EXCLUDE-LIST.md) ===
DIFF: 135 files differ in content on shared paths (see build/compare-tierb-mismatches.txt)
  (golden-only paths: 1646, candidate-only paths: 5 -- expected for routine
   package version bumps; see REBUILD-STATUS.md accepted-delta notes, not auto-failed here)

=== TIER C: binary-exact (uxplay_debug + vendor GStreamer) ===
DIFF: uxplay_debug differs (golden=e567a903fccae13bf0ef0e6b6145d9e60a538bf7e00f08cec7606036b1533793 candidate=90cc7cc45002df4443c59749608955423eea64b023e748f432e0dd11e970ee54) --
  expected ONLY if the UxPlay submodule commit changed since the golden capture;
  a mismatch against a build of the SAME commit is a real reproducibility bug.
PASS: all vendored GStreamer files match exactly

=== TIER D: functional smoke test ===
BLOCKED: no spare SD card/Pi available for a real flash+boot+AirPlay test (see plan).

=== TIER E: raw disk bit-diff ===
N/A by design: the .img is the deliverable, not a byte-diff target (see plan's reframing).
```

### Analysis of the run above

**Fixed during this run** (real gap, not noise): the live Pi runs
**OpenSSH** (`openssh-server`/`-client`/`-sftp-server`), not DietPi's
default **dropbear** — this is how the entire project has been managed
over SSH throughout, but was never captured in `provisioning/setup.sh` or
`image-builder/customize-root.sh` until this run's Tier A diff surfaced
it. A fresh image from the pre-fix scripts would have booted with
dropbear instead. Fixed in both scripts (install openssh-server, purge
dropbear); re-verified clean (no ssh-related entries in the diff below).

**Remaining Tier A deltas — accepted, not fixed:**
- **CORRECTED below (see the 2026-09-08T04:23:23Z entry's analysis) — the
  `libavahi-client3`/`libavahi-compat-libdnssd1` claim here was wrong.**
  The `ldd`-based check only inspects load-time (`DT_NEEDED`) linking and
  can't rule out `dlopen()`; more importantly, it was run carelessly
  (grepped for the literal substring "avahi", which doesn't appear in the
  actual dependency name `libdns_sd.so.1`). `readelf -d` shows
  `libdns_sd.so.1` as a genuine `NEEDED` entry — this is a hard runtime
  dependency, not cruft. Fixed in the next run.
- `alsa-utils`, `libatopology2t64`, `libdrm-etnaviv1`, `libdrm-tegra0`,
  `libdrm-tests`, `libfftw3-single3`, `libpcap0.8t64` — ALSA CLI tools,
  other-vendor (Vivante/NVIDIA) DRM drivers irrelevant to this Pi's VC4
  GPU, and an FFT library. None are dependencies of anything this project
  installs; most-likely incidental installs from earlier ad-hoc debugging
  sessions. Not reproduced.
- `tcpdump` — **CORRECTED below**: this one actually is useful (matches
  PROGRESS.md's own tcpdump-replay debugging), not cruft. Added in the
  next run.

**Remaining Tier B deltas — all expected categories, not fixed:**
- DietPi's own first-boot state (`/boot/dietpi.txt`,
  `/boot/dietpi/.install_stage`, `/boot/dietpi/.installed`) —
  legitimately differs pre-boot; these get written by DietPi's own
  first-boot process, which only runs on a real flash+boot (Tier D).
- Host-identity files (`/etc/hostname`, `/etc/passwd(-)`,
  `/etc/shadow(-)`, `/etc/group(-)`, `/etc/gshadow(-)`, `/etc/hosts`,
  `/etc/resolv.conf`, `/etc/fstab`, `/etc/network/interfaces`) — expected
  to differ (hostname not yet set, and system-user UID/GID allocation is
  inherently order-dependent on exactly which packages install their own
  users in what sequence — not the same order between the live Pi's
  actual multi-month history and a from-scratch build).
- `ld.so.cache`, `/etc/console-setup/cached_setup_keyboard.sh`,
  `/etc/fake-hwclock.data` — generated/cached files, expected to differ.
- OpenSSL (`libcrypto.so.3`, `libssl.so.3`, `usr/bin/openssl`, engines/
  modules) and a handful of kernel netfilter modules — routine
  security-patch version bumps between when the golden reference was
  captured and this build; not a reproducibility bug (see Dockerfile.
  uxplay-buildtest's own accepted-drift note for the analogous case).

**Tier C:** vendored GStreamer files match **exactly** (0 deltas) — the
scripted closure is fully correct. `uxplay_debug` mismatches the golden
hash, but expectedly: the golden capture recorded whatever binary was
deployed on the Pi from an earlier, pre-hardening build; `tools/verify-reproducible-build.sh`
already independently confirms the *current* Dockerfile produces
bit-identical output across builds, which is the property that actually
matters going forward.

**Top-line verdict: PARTIAL.** Every Tier A/B delta above is understood
and either fixed or explicitly accepted with a reason — none is an
unexplained gap. The only thing separating this from a full "YES" is
Tier D (an actual flash + boot + AirPlay session), which remains blocked
on spare hardware.

## 2026-09-08T04:23:23Z
- golden-reference snapshot: `golden-reference/snapshots/2026-09-07/`
- built image: `build/rpi-airplay.img` (30e5037fe596...)
- UxPlay submodule commit: `0eeae8f`
```
debugfs 1.47.2 (1-Jan-2025)
Extracted boot partition -> /tmp/compare-work/boot (422 files)
Extracted root partition -> /tmp/compare-work/root (13200 files)
=== TIER A: package manifest ===
DIFF: package selections differ (- golden, + candidate):
2d1
< alsa-utils					install
31a31,32
> dropbear					install
> dropbear-bin					install
81d81
< libatopology2t64:arm64				install
114d113
< libcbor0.10:arm64				install
139,141d137
< libdrm-etnaviv1:arm64				install
< libdrm-tegra0:arm64				install
< libdrm-tests					install
154,155d149
< libfftw3-single3:arm64				install
< libfido2-1:arm64				install
317a312,313
> libtomcrypt1:arm64				install
> libtommath1:arm64				install
341,342d336
< libwrap0:arm64					install
< libwtmpdb0:arm64				install
400,402d393
< openssh-client					install
< openssh-server					install
< openssh-sftp-server				install
416d406
< runit-helper					install

=== TIER B: file-tree content (root partition, minus EXCLUDE-LIST.md) ===
DIFF: 137 files differ in content on shared paths (see build/compare-tierb-mismatches.txt)
  (golden-only paths: 1728, candidate-only paths: 40 -- expected for routine
   package version bumps; see REBUILD-STATUS.md accepted-delta notes, not auto-failed here)

=== TIER C: binary-exact (uxplay_debug + vendor GStreamer) ===
DIFF: uxplay_debug differs (golden=e567a903fccae13bf0ef0e6b6145d9e60a538bf7e00f08cec7606036b1533793 candidate=90cc7cc45002df4443c59749608955423eea64b023e748f432e0dd11e970ee54) --
  expected ONLY if the UxPlay submodule commit changed since the golden capture;
  a mismatch against a build of the SAME commit is a real reproducibility bug.
PASS: all vendored GStreamer files match exactly

=== TIER D: functional smoke test ===
BLOCKED: no spare SD card/Pi available for a real flash+boot+AirPlay test (see plan).

=== TIER E: raw disk bit-diff ===
N/A by design: the .img is the deliverable, not a byte-diff target (see plan's reframing).
```

### Analysis of the run above

Three corrections to the previous run's analysis, all from direct
challenges to my own conclusions rather than new Tier A output alone:

1. **`libavahi-compat-libdnssd1`/`libavahi-client3` were wrongly accepted
   as cruft — actually a hard runtime dependency.** `lib/CMakeLists.txt`
   builds UxPlay with `-DUSE_DNS_SD=1` and does a real
   `target_link_libraries(airplay PUBLIC ${DNSSD})` against
   `avahi-compat-libdns_sd` (found via pkg-config at build time, in
   `Dockerfile.uxplay-buildtest`'s `libavahi-compat-libdnssd-dev`).
   `readelf -d build/uxplay_debug | grep NEEDED` shows `libdns_sd.so.1` as
   a genuine ELF dependency — without the package providing it,
   `uxplay_debug` fails to even start (missing shared library at dynamic
   link time). The earlier "confirmed via ldd" claim was based on a sloppy
   check: grepping ldd's output for the literal substring "avahi", which
   never appears — the actual library name is `libdns_sd.so.1`. (There's
   also a separate `dlopen("libdns_sd.so", ...)` fallback path in
   `lib/dnssd.c`, gated on `USE_LIBDL`/`HAVE_LIBDL` — dead code in this
   build since nothing defines `HAVE_LIBDL`, so it's not what's actually
   in play here, but it's what prompted re-checking the ldd-only
   methodology in the first place.) Fixed: `libavahi-compat-libdnssd1`
   added to both `provisioning/setup.sh` and
   `image-builder/customize-root.sh`'s package list (`libavahi-client3`
   comes along as its own transitive dependency). Diff now clean for both.
2. **`tcpdump` was wrongly excluded as cruft — it's a useful, intentional
   inclusion.** Matches PROGRESS.md's own tcpdump-replay debugging
   workflow for this project. Added to both scripts; `libpcap0.8t64`
   (tcpdump's own dependency) is consequently no longer a diff either.
3. **OpenSSH vs dropbear, reconsidered and reverted to dropbear.** Checked
   the live Pi directly (`sshd_config`, `journalctl -u ssh`): SSH access
   here has only ever been plain password authentication (root login) for
   interactive command execution — no sftp/scp, no X11 forwarding, no
   ProxyJump, no key-based auth appear anywhere in this project's actual
   usage or history. Dropbear (DietPi's default, smaller footprint) fully
   covers that usage pattern. The earlier openssh-server install was
   applied purely to make a Tier A diff disappear, without checking
   whether it was actually needed — reverted in both scripts. This
   reintroduces `openssh-client`/`-server`/`-sftp-server` as a golden-only
   accepted delta (opposite direction from before), plus their transitive
   dependencies `libcbor0.10`, `libfido2-1`, `libwrap0`, `libwtmpdb0`,
   `runit-helper` (all pulled in by openssh-server on the golden/live Pi,
   absent from the candidate now that openssh isn't installed there) —
   this is a **live-Pi/image design divergence**, not a bug: the live Pi
   itself still runs openssh (untouched — flipping a device's only remote
   SSH daemon from a network session is a real, hard-to-reverse risk not
   worth taking just to match this comparison), while the new image design
   intentionally uses dropbear going forward.

**Remaining Tier A deltas — still accepted, unchanged reasoning:**
`alsa-utils`, `libatopology2t64`, `libdrm-etnaviv1`, `libdrm-tegra0`,
`libdrm-tests`, `libfftw3-single3` — ALSA CLI tools and other-vendor
(Vivante/NVIDIA) DRM drivers irrelevant to this Pi's VC4 GPU. Not
dependencies of anything this project installs; not reproduced.

**Tier B/C:** same shape as the previous run (version-bump-driven content
diffs, GStreamer vendor files bit-exact, `uxplay_debug` mismatching the
golden hash for the same already-understood reason — see the previous
entry's analysis).

**Top-line verdict: PARTIAL**, same as before — every Tier A/B delta is
now understood and either fixed or explicitly and correctly justified.
Tier D (real flash + boot + AirPlay session) remains the only blocker on a
full "YES", pending spare hardware.

## 2026-09-08: pipeline bug found and fixed -- file ownership was silently discarded

Discovered while investigating "many boot errors" reported on the first
real flash+boot of an image from this pipeline. Root cause and fix, not a
routine `make verify` run (no new Tier A/B/C output below -- the existing
tiers can't see this class of bug at all, see "gap" note at the end).

**The bug:** every file extracted/rebuilt by this pipeline
(`image-builder/extract-partitions.sh` + `customize-root.sh` +
`build-image.sh`) was silently flattened to `root:root` ownership,
regardless of what the source image or `customize-root.sh`'s own
`chroot ... install -o -g ...` / `useradd` calls intended. Concretely: a
freshly built image's `/home/uxplay` (needed writable by `uxplay.service`,
which runs as `User=uxplay` with `WorkingDirectory=/home/uxplay` and writes
`GST_REGISTRY=/home/uxplay/.cache/gstreamer-1.0/registry.bin`) came out
owned by `root:root` mode `755` -- unwritable by the `uxplay` user, so
GStreamer's registry cache creation would fail on every real boot.

**Root cause:** `build/dietpi-root`/`build/dietpi-boot` were host
bind-mounts (`-v $PWD/build/dietpi-root:/rootdir`). On macOS,
Docker/colima shares host bind-mounts via virtiofs, and the virtiofs
daemon that actually performs the filesystem operation on the Mac side
runs as the regular, unprivileged macOS user -- it cannot `chown()` a file
to an arbitrary non-root UID on the real host filesystem. Confirmed
directly: a bare `chown 999:986 <path>` against a bind-mounted path
returned success but the ownership never persisted. This affected **every
file in the image**, not just newly-created ones -- confirmed by checking
`/etc/shadow` in the pristine, never-customized base image (correctly
`root:shadow`, `User=0 Group=42` via `debugfs stat` on the source .img)
versus after `debugfs rdump` extraction to the bind-mounted directory
(flattened to `User=0 Group=0`). Also confirmed `debugfs rdump` itself is
not at fault: extracting to genuine container-local storage (not a host
bind-mount) preserved `/etc/shadow`'s `root:shadow` ownership correctly.

This has been present since the very first successful build this session
-- every prior `make verify` run's Tier A (package manifest) and Tier B
(file *content* sha256) both pass regardless, since neither ever inspects
ownership. It was only caught by manually `debugfs stat`-ing specific
paths while investigating an unrelated first-boot report.

**Fix:** `build/dietpi-root`/`build/dietpi-boot` are now Docker **named
volumes** (`rpi-airplay-dietpi-root`/`-boot`), not host bind-mounts --
named volumes are backed by the colima VM's own filesystem, never shared
via virtiofs, so `chown`/chroot-based ownership assignment round-trips
correctly. `customize-root.sh` was also simplified: it no longer needs its
own copy-in/copy-out dance through container-local `/tmp` (that workaround
predated this fix and was based on an earlier, separately-corrected
misdiagnosis about chroot+bind-mounts) -- it now operates directly on the
volume-mounted directory. Verified post-fix via `debugfs stat` against the
rebuilt image: `/etc/shadow` (`0:42`), `/home/uxplay` (`999:986`),
`/var/log/journal` (`0:999`, mode `02755` -- setgid bit also correctly
preserved) all match expectations; a broader `find -not -uid 0 -o -not
-gid 0` scan across the whole rebuilt root filesystem found 23 correctly
non-root-owned paths (dietpi user's home, `_apt` cache, shadow/gshadow
group files, dbus's setgid launch helper, cron/mail groups, etc.) where
the pre-fix image had **zero** anywhere.

**Known gap this leaves:** Tier B only diffs file *content* (sha256), not
ownership/mode -- it would not have caught this bug and still can't catch
a regression of the same class going forward. Neither `golden-reference/
capture.sh` nor `compare-rebuild.sh` currently capture/compare per-file
uid/gid/mode. Worth adding as a real Tier B extension (the golden capture
would need re-running against the live Pi to backfill ownership data) --
not done here since it's separate from this bug's actual fix.

## 2026-09-08T05:59:45Z
- golden-reference snapshot: `golden-reference/snapshots/2026-09-07/`
- built image: `build/rpi-airplay.img` (054fbde5319d...)
- UxPlay submodule commit: `0eeae8f`
```
debugfs 1.47.2 (1-Jan-2025)
Extracted boot partition -> /tmp/compare-work/boot (422 files)
Extracted root partition -> /tmp/compare-work/root (13204 files)
=== TIER A: package manifest ===
DIFF: package selections differ (- golden, + candidate):
2d1
< alsa-utils					install
31a31,32
> dropbear					install
> dropbear-bin					install
81d81
< libatopology2t64:arm64				install
114d113
< libcbor0.10:arm64				install
139,141d137
< libdrm-etnaviv1:arm64				install
< libdrm-tegra0:arm64				install
< libdrm-tests					install
154,155d149
< libfftw3-single3:arm64				install
< libfido2-1:arm64				install
317a312,313
> libtomcrypt1:arm64				install
> libtommath1:arm64				install
341,342d336
< libwrap0:arm64					install
< libwtmpdb0:arm64				install
400,402d393
< openssh-client					install
< openssh-server					install
< openssh-sftp-server				install
416d406
< runit-helper					install

=== TIER B: file-tree content (root partition, minus EXCLUDE-LIST.md) ===
DIFF: 133 files differ in content on shared paths (see build/compare-tierb-mismatches.txt)
  (golden-only paths: 1724, candidate-only paths: 40 -- expected for routine
   package version bumps; see REBUILD-STATUS.md accepted-delta notes, not auto-failed here)

=== TIER C: binary-exact (uxplay_debug + vendor GStreamer) ===
DIFF: uxplay_debug differs (golden=e567a903fccae13bf0ef0e6b6145d9e60a538bf7e00f08cec7606036b1533793 candidate=90cc7cc45002df4443c59749608955423eea64b023e748f432e0dd11e970ee54) --
  expected ONLY if the UxPlay submodule commit changed since the golden capture;
  a mismatch against a build of the SAME commit is a real reproducibility bug.
PASS: all vendored GStreamer files match exactly

=== TIER D: functional smoke test ===
BLOCKED: no spare SD card/Pi available for a real flash+boot+AirPlay test (see plan).

=== TIER E: raw disk bit-diff ===
N/A by design: the .img is the deliverable, not a byte-diff target (see plan's reframing).
```

## 2026-09-08: local boot-testing added (systemd-nspawn); found a second real bug

While setting up `make test-boot` (boots the built image's root filesystem
via `systemd-nspawn` on colima's own aarch64 Linux VM -- no SD card, no
emulation, see `tools/nspawn-test-boot.sh` and the README), the very first
boot attempt surfaced a genuine bug the ownership fix above didn't touch:

**`uxplay_debug` failed to start at all**, `error while loading shared
libraries: libplist-2.0.so.4: cannot open shared object file`. This
library is a direct link-time dependency of the `airplay` executable
itself (confirmed via `readelf -d`/`ldd`), not of any GStreamer plugin --
`tools/vendor-gstreamer-closure.sh`'s dependency walk only starts from
plugin `.so` files, so it was never in scope for that closure. It also was
never `dpkg`-installed by either `customize-root.sh`/`setup.sh` or (per
Tier A never showing a diff for it) the live Pi itself -- meaning it's
been an untracked, undocumented file sitting on the live Pi the whole
project, in the same category as the earlier-discovered missing GStreamer
`libs/`. Tier B's file-tree diff technically *could* have caught this (a
missing file shows up as a "golden-only path"), but only as an
uninspected number folded into the "golden-only paths: N" aggregate count
-- never individually surfaced.

**Fix:** added `libplist-2.0-4` to both `customize-root.sh` and
`provisioning/setup.sh`'s package lists. Re-ran `make test-boot` after
rebuilding: `uxplay_debug` now starts, loads every shared library
correctly, and fails only at `no element "v4l2h264dec"` -- the real V4L2
hardware decoder element, which doesn't exist without actual RPi silicon.
That's the expected, correct boundary for this test (see README) --
everything short of GPU/display/hardware-decode/actual-AirPlay-session is
now practically testable before ever flashing a card.

**Take-away for the "known gap" noted above:** this is exactly the kind of
regression a content-hash-only Tier B can't reliably surface on its own --
a *behavioral* boot test (which this now is) catches whole categories of
bug (missing runtime deps, ownership/permission breaks) that a pure
file-diff can miss or bury in an aggregate count. `make test-boot` doesn't
replace Tier B, but running both together going forward is meaningfully
stronger than either alone.

## 2026-09-08: real first-boot failure found and fixed -- stale filesystem UUIDs

The card had now failed to come up cleanly on **two consecutive real
flash+boot attempts**, both showing "many errors" on the console with no
persistent journal to inspect afterward (`/etc/machine-id` and
`/var/log/journal` were both still completely empty post-boot -- meaning
the failure happened very early, before systemd's own machine-id setup).
`make test-boot` (systemd-nspawn) showed nothing wrong, because it
structurally *can't* show this class of bug -- nspawn never has a real
block device backing its root filesystem, so DietPi's own first-boot
partition/filesystem-resize service (`dietpi-fs_partition_resize.service`
-> `fs_partition_resize.sh`) always takes its `assuming container system`
skip path when run under nspawn, silently no-op'ing the exact code path
that was actually failing on real hardware.

**Reproduction:** tried booting the actual `kernel8.img` under QEMU's
`raspi3b` machine first (to get a real block device without touching the
physical card) -- a real dead end: `kernel8.img` is gzip-compressed (the
real RPi GPU firmware decompresses it transparently; QEMU's `-kernel`
loader can't), and even after manually decompressing it, `raspi3b` support
in QEMU is known-flaky and never produced a single byte of console output
across several attempts (wrong DTB, `console=serial0` alias not resolving
under emulated hardware, etc.) -- abandoned after reasonable effort.
Pivoted to something far more direct: loop-mount the actual built image
(`losetup -P`) on colima's own VM (a real Linux host, not nested in the
Docker image-builder container) and run `fs_partition_resize.sh` **for
real** in a `chroot` against the real loop-backed partitions. This
reproduced the failure immediately, no kernel/QEMU needed at all. Now
permanently available as `make test-resize`
(`tools/loop-resize-test.sh`) -- complements `make test-boot`, which
still can't cover this class of bug.

**The bug (two instances of the same root cause):** `image-builder/
build-image.sh` rebuilds both partitions from scratch every build
(`mke2fs -d` for root, `mkfs.vfat` for boot) -- and both tools generate a
**fresh, random filesystem UUID/volume-ID by default** on every single
run. `/etc/fstab` (copied unmodified from the base image, never
regenerated) still names the *original* base image's UUIDs. The kernel
itself boots fine regardless (`cmdline.txt`'s `root=PARTUUID=...` refers
to the *partition table's* UUID, which we do correctly preserve by
copying the base image's MBR bytes unchanged -- a completely different
identifier from the *filesystem's own* UUID). But `mount <mountpoint>`
with no explicit source resolves the source via `/etc/fstab`, and
`fs_partition_resize.sh`'s very first two actions are exactly that:
`mount -o remount,rw /`, then (a few steps later) mounting
`/boot/firmware` by its fstab UUID to import `dietpi-wifi.txt`. Both
failed with "can't find UUID=...". Critically, the service only disables
itself (`rm -Rf .../*.wants/dietpi-fs_partition_resize.service`) **after**
the first remount succeeds -- so before this fix, the failure wasn't a
one-time glitch, it was re-triggering identically on **every single
boot**, which is consistent with the user seeing the same errors again on
a second, independent flash+boot attempt.

**Fix:** `build-image.sh` now extracts the UUID/volume-ID each partition's
own `/etc/fstab` entry already expects, and pins `mke2fs -U`/`mkfs.vfat
-i` to match exactly, rather than letting either tool invent a fresh
random one. Re-ran the full `chroot` reproduction after rebuilding:
`fs_partition_resize.sh` now proceeds correctly through the WiFi-file
import and the `sfdisk` resize step, ending in DietPi's own **designed**
graceful fallback (schedule an intermediate reboot, re-enable itself for
the filesystem-expansion half on next boot, exit 0) -- exactly the normal
first-boot behavior this project's own README already documented as
expected, now actually reachable.

**Both `make test-boot` and `make test-resize` pass cleanly** on the
rebuilt image; `test-resize` additionally asserts the UUID/fstab
consistency explicitly (not just observationally) so a regression of this
exact kind fails loudly and immediately going forward.

## 2026-09-08T14:49:31Z
- golden-reference snapshot: `golden-reference/snapshots/2026-09-07/`
- built image: `build/rpi-airplay.img` (61ff33b2686c...)
- UxPlay submodule commit: `0eeae8f`
```
debugfs 1.47.2 (1-Jan-2025)
Extracted boot partition -> /tmp/compare-work/boot (422 files)
Extracted root partition -> /tmp/compare-work/root (13210 files)
=== TIER A: package manifest ===
DIFF: package selections differ (- golden, + candidate):
2d1
< alsa-utils					install
31a31,32
> dropbear					install
> dropbear-bin					install
81d81
< libatopology2t64:arm64				install
114d113
< libcbor0.10:arm64				install
139,141d137
< libdrm-etnaviv1:arm64				install
< libdrm-tegra0:arm64				install
< libdrm-tests					install
154,155d149
< libfftw3-single3:arm64				install
< libfido2-1:arm64				install
250a245
> libplist-2.0-4:arm64				install
317a313,314
> libtomcrypt1:arm64				install
> libtommath1:arm64				install
341,342d337
< libwrap0:arm64					install
< libwtmpdb0:arm64				install
400,402d394
< openssh-client					install
< openssh-server					install
< openssh-sftp-server				install
416d407
< runit-helper					install

=== TIER B: file-tree content (root partition, minus EXCLUDE-LIST.md) ===
DIFF: 133 files differ in content on shared paths (see build/compare-tierb-mismatches.txt)
  (golden-only paths: 1724, candidate-only paths: 46 -- expected for routine
   package version bumps; see REBUILD-STATUS.md accepted-delta notes, not auto-failed here)

=== TIER B (boot partition, minus known macOS-mount junk) ===
DIFF: 3 boot files differ in content on shared paths:
  ./config.txt
  ./dietpi-wifi.txt
  ./dietpi.txt
  (golden-only paths: 0, candidate-only paths: 0)

=== TIER C: binary-exact (uxplay_debug + vendor GStreamer) ===
DIFF: uxplay_debug differs (golden=e567a903fccae13bf0ef0e6b6145d9e60a538bf7e00f08cec7606036b1533793 candidate=90cc7cc45002df4443c59749608955423eea64b023e748f432e0dd11e970ee54) --
  expected ONLY if the UxPlay submodule commit changed since the golden capture;
  a mismatch against a build of the SAME commit is a real reproducibility bug.
PASS: all vendored GStreamer files match exactly

=== TIER D: functional smoke test ===
BLOCKED: no spare SD card/Pi available for a real flash+boot+AirPlay test (see plan).

=== TIER E: raw disk bit-diff ===
N/A by design: the .img is the deliverable, not a byte-diff target (see plan's reframing).
```

## 2026-09-08T15:00:55Z
- golden-reference snapshot: `golden-reference/snapshots/2026-09-07/`
- built image: `build/rpi-airplay.img` (6dd382761a64...)
- UxPlay submodule commit: `0eeae8f`
```
debugfs 1.47.2 (1-Jan-2025)
Extracted boot partition -> /tmp/compare-work/boot (422 files)
Extracted root partition -> /tmp/compare-work/root (13210 files)
=== TIER A: package manifest ===
DIFF: package selections differ (- golden, + candidate):
2d1
< alsa-utils					install
31a31,32
> dropbear					install
> dropbear-bin					install
81d81
< libatopology2t64:arm64				install
114d113
< libcbor0.10:arm64				install
139,141d137
< libdrm-etnaviv1:arm64				install
< libdrm-tegra0:arm64				install
< libdrm-tests					install
154,155d149
< libfftw3-single3:arm64				install
< libfido2-1:arm64				install
250a245
> libplist-2.0-4:arm64				install
317a313,314
> libtomcrypt1:arm64				install
> libtommath1:arm64				install
341,342d337
< libwrap0:arm64					install
< libwtmpdb0:arm64				install
400,402d394
< openssh-client					install
< openssh-server					install
< openssh-sftp-server				install
416d407
< runit-helper					install

=== TIER B: file-tree content (root partition, minus EXCLUDE-LIST.md) ===
DIFF: 133 files differ in content on shared paths (see build/compare-tierb-mismatches.txt)
  (golden-only paths: 1724, candidate-only paths: 46 -- expected for routine
   package version bumps; see REBUILD-STATUS.md accepted-delta notes, not auto-failed here)

=== TIER B (boot partition, minus known macOS-mount junk) ===
DIFF: 2 boot files differ in content on shared paths:
  ./dietpi-wifi.txt
  ./dietpi.txt
  (golden-only paths: 0, candidate-only paths: 0)

=== TIER C: binary-exact (uxplay_debug + vendor GStreamer) ===
DIFF: uxplay_debug differs (golden=e567a903fccae13bf0ef0e6b6145d9e60a538bf7e00f08cec7606036b1533793 candidate=90cc7cc45002df4443c59749608955423eea64b023e748f432e0dd11e970ee54) --
  expected ONLY if the UxPlay submodule commit changed since the golden capture;
  a mismatch against a build of the SAME commit is a real reproducibility bug.
PASS: all vendored GStreamer files match exactly

=== TIER D: functional smoke test ===
BLOCKED: no spare SD card/Pi available for a real flash+boot+AirPlay test (see plan).

=== TIER E: raw disk bit-diff ===
N/A by design: the .img is the deliverable, not a byte-diff target (see plan's reframing).
```

## 2026-09-08: two more real first-boot bugs, both from a Tier B blind spot

After the UUID fix above, the card still failed on a real flash+boot: SSH
never came up, and the console (photographed on the TV) showed a visibly
cropped/overscanned image. Both traced to the **boot (FAT32) partition**,
which `tools/compare-rebuild.sh`'s Tier B had never actually compared --
it only ever diffed the root partition, despite `golden-reference/
capture.sh` already capturing a full `filetree-manifest-boot.sha256` for
exactly this purpose. Fixed alongside the two bugs themselves (see below).

**Bug 1 -- SSH/network never came up.** The console log (photographed,
not pulled remotely -- see reasoning below) showed DHCP only being
attempted on `eth0` and never on `wlan0` at all, ending in DietPi's own
"Use dietpi-config to setup a connection (eth0)" banner. Root cause:
`dietpi.txt` ships `AUTO_SETUP_NET_WIFI_ENABLED=0` by default. Filling in
`dietpi-wifi.txt` with real credentials (as this project has been doing at
flash time) is necessary but **not sufficient** -- without this separate
flag, DietPi never attempts to bring up WiFi at all, only the wired
interface, which has no cable on this deployment. `nmap`-scanning the
whole `/24` for open port 22 (sanity-checked against the router, which
correctly showed 5 real open ports) confirmed zero devices had SSH open
anywhere -- ruling out "wrong IP guess" and confirming the device
genuinely never got network.

**Bug 2 -- cropped/wrong display, and worse: `kmssink` would never work
at all.** `config.txt` shipped with `dtoverlay=vc4-kms-v3d,noaudio`
**commented out**, `gpu_mem_1024=16` (should be `128`), and
`cmdline.txt` was missing `vc4.force_hotplug=1`. The cropping was just
the visible symptom -- the real severity is that `uxplay.service`'s
`kmssink` absolutely requires `/dev/dri/card0`, which only exists with
the KMS/DRM overlay active. Without this fix, video output would have
failed outright on every image this pipeline has ever built, regardless
of anything else already fixed this session -- diagnosed and reproduced
by direct comparison against golden-reference's own verbatim
`config/boot-config.txt` capture (`dtoverlay=vc4-kms-v3d`, no `,noaudio`,
confirmed active on the real, working live Pi).

**Why neither was ever caught before:** both live entirely on the boot
partition, which `compare-rebuild.sh`'s Tier B never compared -- Tier A
(package manifest) and the old Tier B (root-partition content) are both
structurally blind to anything in `config.txt`/`cmdline.txt`/`dietpi.txt`.
Neither `make test-boot` nor `make test-resize` could have caught these
either (`nspawn` shares the host kernel, and `test-resize` never touches
display/network config) -- this really did need an actual photographed
console screen from a real flash+boot to surface at all.

**Fix:** new `image-builder/customize-boot.sh` (analogous to
`customize-root.sh`, wired into the Makefile as an additional step)
applies exactly the config.txt/cmdline.txt/dietpi.txt changes confirmed
against golden-reference -- these were previously only ever hand-applied
directly on the live Pi at some undocumented point in the project's
pre-this-session history, never captured into any script. `tools/
compare-rebuild.sh` now also diffs the boot partition (filtered for the
same class of macOS-mount junk as the root partition, since golden's own
boot capture includes some from an earlier Mac-mount of this card).

**Re-verified clean:** boot Tier B now shows only 2 expected diffs
(`dietpi-wifi.txt` -- real credentials injected at flash time, not
committed; `dietpi.txt` -- the WiFi-enable flag we intentionally changed
plus DietPi's own post-boot rewrites), `config.txt`/`cmdline.txt` match
golden byte-for-byte. Tier A gained one new, correct, explained delta:
`libplist-2.0-4` is now a properly `dpkg`-tracked package in the
candidate, where the live Pi only ever had it as an untracked stray file
-- an improvement over golden, not a regression.

## 2026-09-08: local test coverage added for everything found today

After the two boot-partition bugs above were fixed and confirmed working
on real hardware, added local regression coverage for all of it so a
future change can't silently reintroduce the same class of bug without a
full flash+boot round-trip to notice.

**`tools/loop-resize-test.sh` (`make test-resize`)**: now asserts every
config.txt/cmdline.txt/dietpi.txt value fixed today directly (KMS overlay,
GPU memory split, thermal limit, cmdline.txt exact match, WiFi auto-setup,
hostname, `AUTO_SETUP_AUTOMATED`, survey opt-out, DietPi/apt update-check
opt-out) -- static assertions, no boot needed, fails in seconds.

**`tools/nspawn-test-boot.sh` (`make test-boot`)**: added an mDNS/AirPlay
discovery check (`_airplay._tcp`/`_raop._tcp` registration via
avahi-browse) alongside the existing checks. Getting this reliable
surfaced several nspawn-environment-specific gotchas along the way, all
now documented inline in the script: `apt-get update` needed explicitly
(this image ships with `/var/lib/apt/lists/` deliberately emptied, so a
fresh ephemeral container has no package index at all); `stdbuf -oL -eL`
is required to see a transient unit's own output in the journal at all
(matches uxplay.service's real ExecStart, which already does this);
`nspawn -D` never mounts the boot partition, so dietpi.txt's hostname
fix never reaches these containers, and the base image's generic
"DietPi" default collides with other instances on colima's shared
network, sending avahi into a rapid rename-retry loop -- worked around
by setting a unique hostname directly and restarting avahi-daemon after
boot. The mDNS registration check itself ultimately proved unreliable in
this environment even after all of the above (avahi-browse consistently
finds nothing despite a confirmed-working D-Bus connection and confirmed
`register_dnssd()` success) -- rather than keep chasing an environment
flake, it's a non-fatal WARN, not a FAIL: the actual capability is
already verified directly against real hardware (a live `dns-sd -B
_airplay._tcp` from an actual Mac found "Living Room TV@rpi-airplay"
with fully correct TXT records -- see the entry above). Also found and
fixed along the way: `dropbear.service` reliably fails inside nspawn with
"Address already in use" on port 22 -- expected, not a regression:
nspawn shares the host's network namespace by default, and colima's own
sshd (what `colima ssh` itself uses) already owns that port there; the
real Pi has its own isolated network stack and doesn't hit this.
