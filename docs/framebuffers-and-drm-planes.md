# Framebuffers and DRM planes

Status: reference document (see `docs/README.md` for the full set).
Facts below are cited to `file:line` and were verified empirically (real
`drmdump`/`/dev/fb0` dumps), not assumed.

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
  all.** fbcon writes two independent things onto it:
  1. Kernel/systemd boot console *text* — routed away from this tty by
     not passing `console=tty1` on the kernel cmdline (see
     `image-builder/customize-boot.sh`).
  2. A blinking VT cursor, unconditionally, regardless of whether any text
     is routed there — suppressed independently via
     `vt.global_cursor_default=0`.
- Zeroed **once**, early in boot, by `/usr/local/bin/zero-fb0`
  (`uxplay.service`'s `ExecStartPre`). This is a one-shot mitigation, not
  a standing guarantee — nothing re-zeros it if fbcon writes to it again
  later, e.g. if systemd keeps printing boot messages to console for a
  while after `zero-fb0` already ran; not removing `console=tty1` at the
  kernel-cmdline level would leave that gap open regardless of when
  `zero-fb0` runs.
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
  property — currently only used by the overscan feature (inset margins).
- Composites **on top of** the primary plane wherever it covers it
  (standard DRM overlay-plane stacking) — the primary plane is never
  actually invisible, just normally fully covered.

## Why this matters (the actual bug-class connection)

Wherever plane 98 does **not** cover the full screen — currently only
because the mirrored content genuinely isn't 16:9 (pillarbox margins) —
**plane 86's content shows through in the gap**, and plane 86's content
is governed entirely by the kernel's fbcon, a subsystem this codebase
has no direct runtime control over beyond the one-shot `zero-fb0` script
and the two kernel-cmdline flags above. This is why pillarbox margins
show boot text instead of black without those fixes.

**Tooling note**: `tools/drmdump.c` reads both planes' live atomic
properties *and* dumps their actual pixel content — this is the only
reliable way to verify what's really composited on screen. Reading
`/dev/fb0` alone only ever shows plane 86's content in isolation, never
the real composited result once plane 98 is active.

**Not investigated**: whether the many idle planes (43, 62, 74, 109, 120,
... 659) are reserved for anything specific (a cursor plane, a second
CRTC's own primary/overlay pair) — irrelevant to a single-HDMI-output
deployment like this one, so left unresolved rather than assumed.
