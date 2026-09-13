# Framebuffers and DRM planes

Status: reference document, split out 2026-09-13 from the original
combined `video-audio-threading-and-state-machine.md` (see
`docs/README.md` for the full set). Facts below are cited to `file:line`
and were verified empirically (real `drmdump`/`/dev/fb0` dumps), not
assumed.

This system's SoC (Broadcom VC4, `vc4-kms-v3d` DRM/KMS driver) exposes
dozens of DRM planes (`tools/drmdump.c` enumerates all of them: 43, 62,
74, 86, 98, 109, 120, ... up to 659 on this hardware) — standard for an
atomic-KMS driver offering multiple overlay/cursor planes per CRTC. **Only
two are ever actually driven by this project**, and understanding both —
and which is which — is what `docs/video-pipeline.md`'s `HIDDEN` state and
the 2026-09-12/13 boot-console-text bugs (`PROGRESS.md`) both turn on.

## Plane 86 — the primary plane

- Always full-screen (`CRTC_X=0 CRTC_Y=0 CRTC_W=1920 CRTC_H=1080`,
  confirmed via `drmdump` every time it's been checked this project).
- Backed by `/dev/fb0` — the kernel's legacy fbdev interface. Confirmed
  empirically, not assumed: raw bytes read from `/dev/fb0` and converted
  to a PNG matched, pixel for pixel, what was actually showing through on
  this plane (2026-09-13, during the boot-console-text investigation).
- **Owned by the kernel's `fbcon` driver, not by uxplay or GStreamer at
  all.** fbcon writes two independent things onto it:
  1. Kernel/systemd boot console *text*, whenever a `console=` kernel
     cmdline parameter routes output to this tty (fixed 2026-09-13 by
     removing `console=tty1` from `cmdline.txt` — see
     `image-builder/customize-boot.sh`).
  2. A blinking VT cursor, unconditionally, regardless of whether any text
     is routed there — independent bug, needed its own fix
     (`vt.global_cursor_default=0`, same commit).
- Zeroed **once**, early in boot, by `/usr/local/bin/zero-fb0`
  (`uxplay.service`'s `ExecStartPre`). This is a one-shot mitigation, not
  a standing guarantee — nothing re-zeros it if fbcon writes to it again
  later. That gap (systemd kept printing boot messages to console for a
  while *after* `zero-fb0` already ran) was the actual root cause of the
  2026-09-13 "boot log visible again" regression, not a flaw in
  `zero-fb0` itself.
- The **throwaway blank-pipeline mechanism** (`video_renderer.c:1023`,
  `videotestsrc pattern=black num-buffers=1 ! kmssink
  force-modesetting=true`, used by the `DESTROYED` path in
  `docs/video-pipeline.md`) also ultimately paints onto this plane
  (`force-modesetting=true` forces a full CRTC modeset, which targets the
  primary plane) — a real rendered black frame via a fresh, temporary
  kmssink, not a `/dev/fb0` write. This is a *different* mechanism from
  `zero-fb0` that happens to affect the same plane; don't confuse the two
  when debugging.

## Plane 98 — the video overlay plane

- What `kmssink` actually renders decoded mirror-mode video onto (h264 and
  h265 share this in practice, since only one codec is ever active per
  session).
- Geometry is fully dynamic, driven live by kmssink's `render-rectangle`
  property — the **same mechanism** backs both the overscan feature
  (inset margins) and the frozen-frame-hide feature (pushed off-screen via
  a large negative X, see `video_renderer_hide_video()`).
- Composites **on top of** the primary plane wherever it covers it
  (standard DRM overlay-plane stacking) — the primary plane is never
  actually invisible, just normally fully covered.

## Why this matters (the actual bug-class connection)

Wherever plane 98 does **not** cover the full screen — either because the
mirrored content genuinely isn't 16:9 (pillarbox margins) or because
`video_renderer_hide_video()` deliberately pushed it off-screen (`HIDDEN`
state, `docs/video-pipeline.md`) — **plane 86's content shows through in
the gap**, and plane 86's content is governed entirely by the kernel's
fbcon, a subsystem this codebase has no direct runtime control over beyond
the one-shot `zero-fb0` script and the two kernel-cmdline flags above.
This is why "pillarbox margins show boot text instead of black" and
"screen after disconnect shows boot text instead of black" (reported as
two separate-feeling complaints, 2026-09-13) were actually the exact same
root cause.

**Tooling note**: `tools/drmdump.c` reads both planes' live atomic
properties *and* dumps their actual pixel content — this is the only
reliable way to verify what's really composited on screen. Reading
`/dev/fb0` alone only ever shows plane 86's content in isolation, never
the real composited result once plane 98 is active; an earlier point in
this project's history wrongly assumed `/dev/fb0` was fully decoupled from
real scanout, which this fact disproves — see
[[verify_visible_outcome_not_mechanism]].

**Not investigated**: whether the many idle planes (43, 62, 74, 109, 120,
... 659) are reserved for anything specific (a cursor plane, a second
CRTC's own primary/overlay pair) — irrelevant to a single-HDMI-output
deployment like this one, so left unresolved rather than assumed.
