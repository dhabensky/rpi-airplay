# Reference documentation index

Written 2026-09-13 after three consecutive same-night regressions (frozen
first frame, dead audio, audio-resume latency) that each looked fixed in
isolation but kept reopening a neighboring problem — the direct cause was
making changes without a map of who touches what, from which thread,
under what (if any) lock. These documents are that map, split by concern
so each stays independently readable:

- **[video-pipeline.md](video-pipeline.md)** — video threading, shared
  state, the informal pipeline state machine (`NO_PIPELINE` /
  `PLAYING` / `HIDDEN` / `DESTROYED`), and known race windows.
- **[audio-pipeline.md](audio-pipeline.md)** — audio threading, the two
  separate audio lifecycles (RTP-receiving vs GStreamer rendering), and
  the `conn_request()` finding that's the leading hypothesis for the
  currently-open audio-dies bug.
- **[framebuffers-and-drm-planes.md](framebuffers-and-drm-planes.md)** —
  the primary vs overlay DRM plane layering that explains the
  2026-09-12/13 boot-console-text bug class.
- **[upstream-comparison.md](upstream-comparison.md)** — diff summary
  against pristine upstream `FDH2/UxPlay` tag `v1.73.7`
  (submodule commit `df67c21`), file by file, with the behaviorally
  significant changes called out.

Originally one combined document
(`video-audio-threading-and-state-machine.md`); split 2026-09-13 per
request once it proved useful, so each concern could be read and updated
independently.

See `bugs/` for specific bug investigations that reference these (notably
`bugs/2026-09-13-audio-dies-on-repeated-track-switch-setup.md`), and
`PROGRESS.md` for the full chronological project history.
