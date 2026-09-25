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

Older runs were not summarised or dropped — they are verbatim, one file per
period, under `docs/archive/`:
[`REBUILD-STATUS-2026-09-08--2026-09-09.md`](docs/archive/REBUILD-STATUS-2026-09-08--2026-09-09.md)
(first real entries, plus the ownership/UUID/first-boot bugs they found) and
[`REBUILD-STATUS-2026-09-14--2026-09-15.md`](docs/archive/REBUILD-STATUS-2026-09-14--2026-09-15.md).

## 2026-09-22T02:35:46Z
- golden-reference snapshot: `golden-reference/snapshots/2026-09-14/`
- built image: `build/rpi-airplay.img` (f71346b39ce5...) -- the `.img` the
  Tier A/B/C results below were computed against; later rebuilds of this
  tree have since overwritten that file (see the next entry).
- UxPlay submodule commit: `4ebd98a`
```
debugfs 1.47.2 (1-Jan-2025)
Extracted boot partition -> /tmp/compare-work/boot (422 files)
Extracted root partition -> /tmp/compare-work/root (13306 files)
=== TIER A: package manifest ===
PASS: package selections identical

=== TIER B: file-tree content (root partition, minus EXCLUDE-LIST.md) ===
DIFF: 15 files differ in content on shared paths (see build/compare/tierb-mismatches.txt)
  (golden-only paths: 16, candidate-only paths: 18 -- expected for routine
   package version bumps; see REBUILD-STATUS.md accepted-delta notes, not auto-failed here)

=== TIER B (boot partition, minus known macOS-mount junk) ===
DIFF: 2 boot files differ in content on shared paths:
  ./cmdline.txt
  ./dietpi-wifi.txt
  (golden-only paths: 0, candidate-only paths: 0)

=== TIER C: binary-exact (uxplay_debug + vendor GStreamer) ===
DIFF: uxplay_debug differs (golden=f7145b5ac591d7fbcf8b9a358c7fbb67197a3c2dc2fcda8b3f66d87b9fdd69e7 candidate=b2dcc44d1f673c8186c78863fca79166f5b95ddff5c1538dc9becd46885abcfa) --
  expected ONLY if the UxPlay submodule commit changed since the golden capture;
  a mismatch against a build of the SAME commit is a real reproducibility bug.
PASS: all vendored GStreamer files match exactly

=== TIER D: functional smoke test ===
BLOCKED: no spare SD card/Pi available for a real flash+boot+AirPlay test (see plan).

=== TIER E: raw disk bit-diff ===
N/A by design: the .img is the deliverable, not a byte-diff target (see plan's reframing).
```

This run shipped the on-device diagnostics (`log-ts` log timestamping via
`uxplay.service`, plus `drmdump` and `synthetic-client`). Of the 18
candidate-only paths, exactly 3 are new here -- `/usr/local/bin/log-ts`,
`/usr/local/bin/drmdump`, `/usr/local/bin/synthetic-client`. The other 15
predate this change (the idle-menu/overscan/zero-fb0 units and scripts,
`libgstpango.so`, and DietPi/`personal.env` config files the 2026-09-14
golden capture does not contain).
`./etc/systemd/system/uxplay.service` was
already in Tier B's mismatch set for the same reason (its ExecStart now
also pipes through `log-ts`). The other 14 Tier B mismatches are the
host-identity/config files of the existing accepted-delta categories plus
`./etc/default/uxplay` and `./usr/local/bin/uxplay_debug`; the 2
boot-partition mismatches (`cmdline.txt`, `dietpi-wifi.txt`) come from
`personal.env`'s WiFi credentials, which the golden capture cannot
contain by design (see `golden-reference/EXCLUDE-LIST.md`). Which of
these were already differing in the previous run was not re-checked --
only the current run's list was enumerated. No golden-reference re-capture was
done: the snapshot is a record of the live Pi as of 2026-09-14, and
re-capturing it is a separate, deliberate action.

## 2026-09-22T03:32:00Z
- golden-reference snapshot: `golden-reference/snapshots/2026-09-14/` (not re-compared)
- built image: `build/rpi-airplay.img` (a6aaa9628de5...)
- UxPlay submodule commit: `4ebd98a`

`make image` only -- no `make verify` in this run. Rebuilt after the review
round that made `log-ts` `uxplay.service`'s main process (`ExecStart=
/usr/local/bin/log-ts -- /usr/bin/stdbuf -oL -eL /usr/local/bin/uxplay_debug
...`, no `/bin/bash -c` and no pipeline). The built `.img`'s partitions were
re-extracted with `image-builder/extract-partitions.sh` (422 boot / 13306 root
files) and the shipped binaries are sha256-identical to the `build/` artifacts:

```
88a15a48424bca6e800dacb1a546af16c419ee16598a53d123a108b4d62dd59c  usr/local/bin/log-ts
93dd36b3a2d23a10454d3758652ea11ff357170bac14e2879d3650a62de2fd8f  usr/local/bin/drmdump
e6dc4863cded74e53b4a42172362c7fcf6d33501f88361ca4ddf5e6283386ebb  usr/local/bin/synthetic-client
eca8afd5359f3e5130bf77aa93ecd22f19610c4fae77f8b0fd0ee23df16d5a8e  usr/local/bin/menu-render
b2dcc44d1f673c8186c78863fca79166f5b95ddff5c1538dc9becd46885abcfa  usr/local/bin/uxplay_debug
```

Tier A/B/C were not re-run: the only build inputs that changed since the
previous entry are `tools/log-ts.c` and `uxplay.service`, both already in
that entry's accepted-delta lists.
