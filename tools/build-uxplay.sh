#!/bin/bash
# Builds uxplay_debug against the shared Dockerfile tooling image, writing
# the result to the given output path. One build recipe shared by `make
# uxplay`, tools/deploy.sh, and tools/verify-reproducible-build.sh, instead
# of each carrying its own copy of the same docker invocation.
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
# Usage: tools/build-uxplay.sh <output-path>
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:?usage: $0 <output-path>}"
mkdir -p "$(dirname "$out")"
out_abs="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

docker build -q -t rpi-airplay-buildenv -f Dockerfile .

docker run --rm \
  -v "$PWD/UxPlay":/mnt/UxPlay-src:ro \
  -v "$out_abs":/out/uxplay_debug \
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
  '
