# Framebuffers and DRM planes

Status: reference document (see `docs/README.md` for the full set).
Checked against submodule commit `08abb3c`; the plane/pixel facts were
verified empirically (real `drmdump`/`/dev/fb0` dumps), not assumed.
Citations name a file plus a symbol, unit or flag, never a line number, so
a citation that has gone stale fails a grep instead of quietly pointing at
the wrong place.

This system's SoC (Broadcom VC4, `vc4-kms-v3d` DRM/KMS driver) exposes
dozens of DRM planes (`tools/drmdump.c` enumerates all of them: 43, 62,
74, 86, 98, 109, 120, ... up to 659 on this hardware) — standard for an
atomic-KMS driver offering multiple overlay/cursor planes per CRTC. **Only
two are ever actually driven by this project**, and understanding both —
and which is which — is what the pillarbox-margin boot-text issue below
turns on.

## Plane 86 — the primary plane

- Always full-screen (`CRTC_X=0 CRTC_Y=0 CRTC_W=1920 CRTC_H=1080`,
  confirmed via `drmdump` every time it's been checked this project).
- Backed by `/dev/fb0` — the kernel's legacy fbdev interface. Confirmed
  empirically, not assumed: raw bytes read from `/dev/fb0` and converted
  to a PNG match, pixel for pixel, what's actually showing through on
  this plane.
- **Owned by the kernel's `fbcon` driver, not by uxplay or GStreamer at
  all — but only until something else takes DRM master over the device.**
  fbcon writes two independent things onto it:
  1. Kernel/systemd boot console *text* — kept visible via `console=tty1`
     on the kernel cmdline (never stripped; see
     `image-builder/customize-boot.sh`), needed for real boot-time
     debugging (an earlier removal of
     `console=tty1` fixed the pillarbox-text bug below but made the boot
     log itself unreadable, which turned out to matter more in practice).
  2. A blinking VT cursor, unconditionally, regardless of whether any text
     is routed there — suppressed independently via
     `vt.global_cursor_default=0`.
- Zeroed **twice** during boot, then painted over with the idle menu
  screen — all three via plain `write()`s into `/dev/fb0`'s backing
  memory, not DRM calls, so each works regardless of who currently holds
  DRM master (same technique, see `/usr/local/bin/zero-fb0`'s own header
  comment):
  1. Early, by `/usr/local/bin/zero-fb0`
     (`uxplay.service`'s `ExecStartPre=`,
     `image-builder/files/etc/systemd/system/uxplay.service`) — before
     uxplay itself starts.
  2. Late, by `zero-fb0-late.service`
     (`image-builder/files/etc/systemd/system/zero-fb0-late.service`,
     `After=multi-user.target`) — a second pass once boot console output
     has genuinely stopped, closing the race window where systemd could
     still print to console after the early zero already ran.
  3. `uxplay-menu.service`
     (`image-builder/files/etc/systemd/system/uxplay-menu.service`,
     `After=uxplay.service zero-fb0-late.service`, started by that unit's
     `Wants=`) then paints the idle menu (device name/IP/WiFi SSID/
     instructions) into the same buffer, and repaints it whenever a session
     ends, `/etc/default/uxplay` changes, or its refresh interval elapses
     (`refresh_secs` in `tools/uxplay-menu.c`, 300s, overridable via
     `UXPLAY_MENU_REFRESH_SECS`).
  `uxplay.service` claims DRM master via its own kmssink essentially at
  startup — independent of any client connecting — and holds it for the
  service's whole lifetime, per `/usr/local/bin/zero-fb0`'s own header
  comment ("fbcon reasserts its content back onto the DRM primary plane
  whenever no other client holds DRM master"). So once `uxplay.service`
  is running, fbcon can never write to plane 86 again regardless of
  `console=tty1` — whatever was last written directly into `/dev/fb0`
  (the late zero, then the menu) simply stays there, visible through
  plane 98's gaps exactly like the boot text used to be.
- Also zeroed at **runtime**, from inside uxplay itself:
  `video_renderer_blank_primary_plane()` (`renderers/video_renderer.c`) is
  called by `video_renderer_choose_codec()` every time a connection
  (re)confirms `PLAYING`, so nothing stale is left to bleed through a
  non-16:9 source's pillarbox margins. Its body
  (`blank_primary_plane_cb()`, deferred onto the main loop with
  `g_idle_add()`) sizes the buffer from
  `/sys/class/graphics/fb0/virtual_size` + `bits_per_pixel` and writes
  zeros to `/dev/fb0` — the same plain-write technique as `zero-fb0`,
  reimplemented in C so the library never shells out to a deployment
  script. It is *not* a DRM or kmssink call and never touches plane 98.

## Plane 98 — the video overlay plane

- What `kmssink` actually renders decoded mirror-mode video onto (h264 and
  h265 share this in practice, since only one codec is ever active per
  session).
- Geometry is fully dynamic, driven live by kmssink's `render-rectangle`
  property. `apply_render_rectangle()` (`renderers/video_renderer.c`) is
  the single place that sets it, for two purposes:
  - **Overscan insets** — `video_renderer_set_overscan()`, fed by the
    `-overscan l:r:t:b` startup flag and by `"l r t b\n"` lines arriving
    on the `-ofifo` FIFO (`uxplay-menu` is the writer in this deployment;
    `uxplay.cpp`'s `overscan_fifo_watch_callback()` is the reader). An
    out-of-range set is logged and ignored in favour of the full screen.
  - **Hiding video on disconnect** — `video_renderer_release_display()`
    parks the full-size rectangle at `x = -screen_width`, off the left
    edge, so plane 86's idle menu is what's left visible. A degenerate
    `<0,0,1,1>` rect would not work: kmssink's aspect-preserving fit
    rounds it to <= 0 and skips the DRM commit entirely.
- Composites **on top of** the primary plane wherever it covers it
  (standard DRM overlay-plane stacking) — the primary plane is never
  actually invisible, just normally fully covered.

## Why this matters (the actual bug-class connection)

Wherever plane 98 does **not** cover the full screen — because the
mirrored content genuinely isn't 16:9 (pillarbox margins), or because no
client is connected at all — **plane 86's content shows through in the
gap**, and plane 86's content is whatever was last written directly into
`/dev/fb0`: fbcon's boot text, until `uxplay.service` starts and the
zero/menu-paint chain above takes over for the rest of that boot. This is
why pillarbox margins used to show boot text instead of black before
`zero-fb0`/`zero-fb0-late.service` existed, and it's also the entire
mechanism behind the idle menu screen itself — `uxplay-menu-render`
writes into this same plane, and once `uxplay.service` holds DRM master,
nothing else can overwrite it until the next explicit write.

Once boot is done, two processes write that plane, alternating per session:

- **Session start** — uxplay itself, entirely internally:
  `video_renderer_choose_codec()` calls
  `video_renderer_blank_primary_plane()`, wiping the menu to black so it
  cannot show through plane 98's margins.
- **Session end** — `uxplay-menu` (`tools/uxplay-menu.c`) repaints the menu
  via `/usr/local/bin/uxplay-menu-render`. It learns the session ended over
  uxplay's `-efifo` channel: uxplay's `event_fifo_session_end()` writes a
  `session-end` line and `uxplay-menu` reads
  `/run/uxplay-events.fifo`. `UxPlay/event_fifo.h` documents that
  protocol, including the fact that a dropped write swallows a later
  transition, so the last line can read `session-end` mid-session.
  `uxplay-menu` also repaints when `/etc/default/uxplay` changes and on its
  own refresh interval.

**Tooling note**: `tools/drmdump.c` reads both planes' live atomic
properties *and* dumps their actual pixel content — this is the only
reliable way to verify what's really composited on screen. Reading
`/dev/fb0` alone only ever shows plane 86's content in isolation, never
the real composited result once plane 98 is active.

**Not investigated**: whether the many idle planes (43, 62, 74, 109, 120,
... 659) are reserved for anything specific (a cursor plane, a second
CRTC's own primary/overlay pair) — irrelevant to a single-HDMI-output
deployment like this one, so left unresolved rather than assumed.
