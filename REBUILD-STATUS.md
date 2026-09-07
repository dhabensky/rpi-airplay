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
