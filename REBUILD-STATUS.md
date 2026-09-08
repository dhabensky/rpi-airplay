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
- `libavahi-client3`, `libavahi-compat-libdnssd1` — confirmed via
  `ldd build/uxplay_debug` that the binary does **not** link against
  either at runtime. Leftover cruft on the live Pi from some earlier,
  undocumented action (plausibly avahi/mDNS troubleshooting mentioned in
  PROGRESS.md), not a functional requirement.
- `alsa-utils`, `libatopology2t64`, `libdrm-etnaviv1`, `libdrm-tegra0`,
  `libdrm-tests`, `libfftw3-single3`, `libpcap0.8t64`, `tcpdump` — ALSA
  CLI tools, other-vendor (Vivante/NVIDIA) DRM drivers irrelevant to this
  Pi's VC4 GPU, an FFT library, and a packet-capture tool. None are
  dependencies of anything this project installs; most-likely incidental
  installs from earlier ad-hoc debugging sessions (`tcpdump` matches
  PROGRESS.md's own mention of a raw-tcpdump-replay experiment). Not
  reproduced.

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
