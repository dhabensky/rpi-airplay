#!/bin/bash
# Builds the drmdump/drmpaint diagnostic tools. drmdump is shipped in the
# image (the Makefile's build/bin/drmdump target, installed by
# customize-root.sh); drmpaint is built here too but stays hand-deployed.
# Same shared Dockerfile tooling image as everything else, produces real
# aarch64 binaries on this host the same way uxplay_debug does (colima's VM
# is native arm64 on Apple Silicon -- no cross-compilation flags needed).
#
# Usage: tools/build-drmdump.sh [output-dir]   (default: build/bin)
# output-dir must live under $PWD (or elsewhere under $HOME), NOT the
# system /tmp -- colima only mounts $HOME into its VM, so a bind-mount of
# a /tmp path silently shows up as an empty directory inside the container
# (verified empirically; see image-builder/refresh-base-image.sh's header
# for the same gotcha hit elsewhere in this project).
set -euo pipefail
cd "$(dirname "$0")/.."

outdir="${1:-build/bin}"
mkdir -p "$outdir"
outdir_abs="$(cd "$outdir" && pwd)"

docker build -q -t rpi-airplay-buildenv -f Dockerfile .

docker run --rm \
  -v "$PWD/tools":/mnt/tools:ro \
  -v "$outdir_abs":/out \
  rpi-airplay-buildenv \
  bash -c '
    set -euo pipefail
    gcc -O2 -Wall -o /out/drmdump /mnt/tools/drmdump.c $(pkg-config --cflags --libs libdrm)
    gcc -O2 -Wall -o /out/drmpaint /mnt/tools/drmpaint.c $(pkg-config --cflags --libs libdrm)
  '

# The container writes into /out and exits 0 even when $outdir is a path the
# Docker VM doesn't share, leaving the host side empty.
./tools/check-build-artifact.sh "$outdir_abs/drmdump"
./tools/check-build-artifact.sh "$outdir_abs/drmpaint"
echo "Built $outdir/drmdump and $outdir/drmpaint"
