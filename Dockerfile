# One shared, disposable build/test/tool environment for this whole
# project: uxplay-buildtest, unit-tests, image-builder, gstreamer-closure,
# and drmdump-buildtest all need the identical Debian base digest, and
# their package requirements don't conflict, so one image covers all of
# them -- this is the union of everything they need.
#
# This image only ever contains TOOLING, never a baked-in build action or
# copied-in application source -- every actual build/test/compute step
# (compiling uxplay_debug, running the unit tests, extracting/customizing
# the Pi image, computing the vendored GStreamer closure, compiling
# drmdump/drmpaint) happens via `docker run` against this one image, with
# source bind-mounted read-only and output written to a bind-mounted
# directory. See the Makefile and tools/*.sh for each specific
# invocation. The one COPY below (apt-lists/) is build-environment
# configuration, not application source -- it has to be baked in at
# `docker build` time for apt to resolve against it at all.
#
# Pinned by digest, not the mutable "trixie-slim" tag, so the base image
# content can't silently drift between builds (see
# tools/verify-reproducible-build.sh). Re-pin deliberately (docker pull
# debian:trixie-slim && docker inspect --format='{{index .RepoDigests 0}}'
# debian:trixie-slim) when a newer base is wanted.
FROM debian@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132

# No `apt-get update` here: it would query whatever Debian currently
# publishes, and the exact byte content of everything this image computes
# from these packages (e.g. build/vendor-gstreamer/, from the gstreamer-
# plugins-* below) would then depend on exactly when the image happens to
# be built, not just on what's in this file. Install directly against the
# frozen index in apt-lists/ (regenerated deliberately via `make
# refresh-buildenv-apt-lists` when packages should actually move) instead.
COPY apt-lists/ /var/lib/apt/lists/
RUN apt-get -o Acquire::Check-Valid-Until=false install -y --no-install-recommends \
    git cmake build-essential pkg-config \
    libssl-dev libplist-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    libavahi-compat-libdnssd-dev \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gstreamer1.0-libav gstreamer1.0-alsa \
    gstreamer1.0-tools \
    e2fsprogs dosfstools mtools fdisk \
    binutils libdrm-dev \
    ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
