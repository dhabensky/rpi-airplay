# Reference documentation index

Maps of who touches what, from which thread, under what (if any) lock,
split by concern so each stays independently readable:

- **[video-pipeline.md](video-pipeline.md)** — video threading, shared
  state, the informal pipeline state machine (`NO_PIPELINE` /
  `PLAYING` / `HIDDEN` / `DESTROYED`), the `video_connect_epoch` guard on
  `video_renderer_release_display()`, `render_health_callback()`'s
  decode-without-render watchdog, and known race windows.
- **[audio-pipeline.md](audio-pipeline.md)** — audio threading, the two
  separate audio lifecycles (RTP-receiving vs GStreamer rendering), the
  RTP-timestamp-to-NTP-time sync state, `raop_buffer.c`'s resend rate limit
  and stall-timeout force-skip, and `conn_request()`'s connection-type
  classification.
- **[framebuffers-and-drm-planes.md](framebuffers-and-drm-planes.md)** —
  the primary vs overlay DRM plane layering, who writes `/dev/fb0` and
  when, and the two purposes kmssink's `render-rectangle` serves
  (`video_renderer_set_overscan()` insets via `-overscan`/`-ofifo`, and
  `video_renderer_release_display()` parking video off-screen).
- **[upstream-comparison.md](upstream-comparison.md)** — diff summary
  of submodule commit `08abb3c` against pristine upstream `FDH2/UxPlay`
  tag `v1.73.7` (= upstream commit `df67c21`), file by file, with the
  behaviorally significant changes called out.
- **[threadtest.md](threadtest.md)** — `UxPlay/tools/synthetic-client.cpp`,
  a standalone synthetic AirPlay client (a genuinely separate process, not
  code compiled into `uxplay.cpp`) that drives the real
  httpd/`conn_request()`/`raop_handler_setup()`/`raop_rtp_thread_udp` over
  loopback. Covers all nine modes (`threadtest`, `mirrortest`,
  `ntpresync`, `resendstorm`, `resendrecovery`, `peekstall`, `shorturl`,
  `shorturlfrag`, `shorturlsweep`); the filename predates the extra modes.
- **[testing.md](testing.md)** — full test framework overview: every test
  type/suite, what it requires (unit/Docker/real Pi hardware), and —
  importantly — what each one does *not* check.

See **[bugs/](bugs/)** for specific bug investigations (one file per bug:
symptom, root cause, fix, verification). Chronological project history is
`PROGRESS.md` for the current period and **[archive/](archive/)** for
earlier ones (`PROGRESS-<from>--<to>.md`, plus the matching
`REBUILD-STATUS-<from>--<to>.md` `make verify` runs) — verbatim, nothing
summarised.
