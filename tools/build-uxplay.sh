#!/bin/bash
# Builds uxplay_debug (and tools/synthetic-client.cpp's binary, alongside
# it in the same directory) against the shared Dockerfile tooling image,
# writing the result to the given output path. One build recipe shared by
# `make uxplay`, tools/verify-reproducible-build.sh and tools/pytest's
# uxplay_binary fixture, instead of each carrying its own copy of the same
# docker invocation.
#
# UxPlay/ is bind-mounted read-only and copied to a container-local path
# (/src/UxPlay) before building -- keeps the host's submodule checkout
# untouched (no stray build/ dir appearing inside a tracked git submodule)
# and gives -ffile-prefix-map a fixed absolute path to strip.
#
# SOURCE_DATE_EPOCH + -ffile-prefix-map make the build reproducible:
# without them, embedded timestamps and the /src/UxPlay absolute build
# path would make two otherwise-identical builds diverge byte-for-byte.
# Pinned to the UxPlay submodule commit's own timestamp (not `date`), so
# it's a function of the pinned source, not of when the build happened to
# run.
#
# Usage: tools/build-uxplay.sh <output-path> [source-dir]
#   source-dir defaults to ./UxPlay. Pass an alternate checkout (e.g. a
#   `git worktree` of a different ref, see tools/pytest/conftest.py's
#   uxplay_binary fixture) to build that ref instead, without touching
#   the main submodule checkout.
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:?usage: $0 <output-path> [source-dir]}"
src="${2:-$PWD/UxPlay}"
mkdir -p "$(dirname "$out")"
# Docker's bind-mount creates the host path as a DIRECTORY if it doesn't
# already exist -- fine on a repeat build (the previous run's file is
# already there), silently wrong on a genuinely fresh output path (the
# container's own `cp` then lands inside that directory instead of at the
# path itself). touch+chmod first so the mount always targets a real,
# executable file -- `cp` writing into an already-existing destination
# inode (that's what the bind mount is) doesn't change its permission
# bits, so a plain `touch` alone would leave it non-executable.
touch "$out"
chmod +x "$out"
synth_out="$(dirname "$out")/synthetic-client"
touch "$synth_out"
chmod +x "$synth_out"
out_abs="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
synth_out_abs="$(cd "$(dirname "$synth_out")" && pwd)/$(basename "$synth_out")"
src_abs="$(cd "$src" && pwd)"

docker build -q -t rpi-airplay-buildenv -f Dockerfile .

docker run --rm \
  -v "$src_abs":/mnt/UxPlay-src:ro \
  -v "$out_abs":/out/uxplay_debug \
  -v "$synth_out_abs":/out/synthetic-client \
  -e SOURCE_DATE_EPOCH=1788797385 \
  rpi-airplay-buildenv \
  bash -c '
    set -euo pipefail
    mkdir -p /src
    cp -r /mnt/UxPlay-src /src/UxPlay
    cd /src/UxPlay
    mkdir build && cd build
    cmake .. -DNO_X11_DEPS=ON -DUSE_DNS_SD=1 \
      -DCMAKE_C_FLAGS="-ffile-prefix-map=/src/UxPlay=." \
      -DCMAKE_CXX_FLAGS="-ffile-prefix-map=/src/UxPlay=."
    make -j"$(nproc)"
    make install
    uxplay -v 2>&1 | head -5 || uxplay -h 2>&1 | head -5
    cp /usr/local/bin/uxplay /out/uxplay_debug
    if [ -f /src/UxPlay/build/synthetic-client ]; then
      cp /src/UxPlay/build/synthetic-client /out/synthetic-client
    else
      echo "(no tools/synthetic-client.cpp target at this ref -- skipping)"
    fi
  '

# The container can copy to /out/uxplay_debug and exit 0 while the host file
# stays 0 bytes, if $out is on a path the Docker VM doesn't share.
./tools/check-build-artifact.sh "$out_abs"
