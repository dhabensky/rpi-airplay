#!/bin/bash
# Builds log-ts, the log-timestamping wrapper shipped in the image (invoked
# by `make image` via the Makefile's build/bin/log-ts target, then
# installed by customize-root.sh and used as uxplay.service's ExecStart).
# Same shared Dockerfile tooling image as everything else, produces a real
# aarch64 binary the same way uxplay_debug does (colima's VM is native arm64
# on Apple Silicon -- no cross-compilation flags needed).
#
# Usage: tools/build-log-ts.sh [output-dir]   (default: build/bin)
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
    gcc -O2 -Wall -o /out/log-ts /mnt/tools/log-ts.c
  '
echo "Built $outdir/log-ts"
