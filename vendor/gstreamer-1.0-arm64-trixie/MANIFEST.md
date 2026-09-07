# Vendored GStreamer 1.0 runtime plugins (arm64, Debian 13 "trixie")

**Status: reproducibility gap, not yet a scripted build. See below.**

These files are the exact GStreamer element plugins + support binaries
running on the Pi as of 2026-09-07, pulled directly from a live,
working device:

- `plugins/*.so` — 18 plugin modules (from `/usr/lib/aarch64-linux-gnu/gstreamer-1.0/`)
- `gst-plugin-scanner` — plugin scanner helper binary
- `liborc-0.4.so.0` — Orc runtime library several plugins link against

## Why these are checked in as binary blobs instead of built from source

`apt install gstreamer1.0-plugins-good gstreamer1.0-plugins-bad` pulls 350+
packages and 750MB+ of X11/Wayland/dbus/PulseAudio/ONNX-runtime/OpenEXR
dependencies that are completely unrelated to this project's headless
kmssink + v4l2 + alsa pipeline, on a device with a 2GB SD card.

Instead, these specific files were hand-extracted from a real `apt install`
done in a disposable environment (matching Debian trixie arm64), by running
UxPlay's actual GStreamer pipeline string, finding which plugin .so files
`gst-inspect`/the pipeline actually load, and copying just those out via
`ldd`-based dependency resolution — **the extraction was done manually,
interactively, over an SSH session, and the exact steps were not scripted
at the time.** That is the single biggest reproducibility gap in this
project: if this file set is ever lost, reproducing it requires redoing
that manual exploration from scratch.

## What "fixing this properly" looks like (not yet done)

A `Dockerfile` (or a stage added to `Dockerfile.uxplay-buildtest`) that:
1. Starts from `debian:trixie-slim` (arm64/via colima, matches this Pi's OS)
2. `apt-get install gstreamer1.0-plugins-good gstreamer1.0-plugins-bad
   gstreamer1.0-plugins-base gstreamer1.0-libav gstreamer1.0-alsa
   gstreamer1.0-tools` (the full closure, exactly as
   `Dockerfile.uxplay-buildtest` already does for the *build* environment)
3. Runs `ldd` transitively over the specific plugin .so files this
   project's pipeline string needs (`libgstalsa`, `libgstapp`,
   `libgstaudioconvert`, `libgstaudioresample`, `libgstautodetect`,
   `libgstcoreelements`, `libgstdebug`, `libgstkms`, `libgstlevel`,
   `libgstlibav`, `libgstplayback`, `libgsttypefindfunctions`,
   `libgstvideo4linux2`, `libgstvideoconvertscale`, `libgstvideofilter`,
   `libgstvideoparsersbad`, `libgstvideorate`, `libgstvolume` +
   `gst-plugin-scanner` + `liborc`) and copies exactly that closure out
   as a build artifact.
4. Replaces this directory's contents, with a manifest recording the
   Debian package versions each file came from.

Until that exists, treat this directory as the source of truth for "what
actually works on this hardware" and `provisioning/setup.sh` installs it
as-is via `install(1)`, same as any other vendored binary dependency.
