# Build system for rpi-airplay -- see the plan/README for the full
# rationale. `make image` produces a complete, ready-to-flash .img from a
# clean checkout; `make verify` checks it against a golden-reference
# capture from the live Pi. Everything here calls into plain shell/Docker
# recipes under tools/ and image-builder/ -- this file is the dependency
# graph and the one documented entry point, not where the actual logic
# lives.
.PHONY: image image-xz uxplay vendor-gstreamer base-image golden-reference verify \
        reproducible-check refresh-base-image test-boot test-resize clean

IMAGE_BUILDER_TAG := rpi-airplay-image-builder
GSTREAMER_CLOSURE_TAG := rpi-airplay-gstreamer-closure

# Optional, gitignored, personal (WiFi creds, overscan tuning, ... -- see
# personal.env.example). Empty if the file doesn't exist -- `make image`
# must produce a complete, working (if less personalized) image either way.
PERSONAL_ENV := $(wildcard personal.env)

# Named Docker volumes (NOT host bind-mounts) for the intermediate
# extracted/customized partition trees. Required, not a style choice: on
# macOS, Docker/colima shares host bind-mounts via virtiofs, whose daemon
# runs as your regular unprivileged macOS user -- it silently can't chown()
# files to arbitrary non-root UIDs (confirmed empirically: even a bare
# `chown` on a bind-mounted path returns success but doesn't persist). That
# would flatten every non-root-owned file in the image (package-installed
# service users, /home/uxplay, /var/log/journal, ...) to root:root on every
# build. Named volumes are backed by the colima VM's own filesystem, not
# shared via virtiofs, so ownership round-trips correctly. Only the final,
# opaque .img file (no per-file ownership semantics visible to the host)
# is safe to move across the host bind-mount, which is why only that last
# step still uses `-v "$$PWD":/work`.
DIETPI_ROOT_VOLUME := rpi-airplay-dietpi-root
DIETPI_BOOT_VOLUME := rpi-airplay-dietpi-boot
# Persists downloaded .deb files across builds (customize-root.sh's
# apt-get install is the single largest per-build cost, ~2 of the ~5
# minute image-assembly pipeline, almost entirely re-downloading the same
# unchanged packages every time otherwise). Deliberately NOT wiped by the
# `docker volume rm -f` below -- that's specifically for the intermediate
# rootfs/bootfs trees, which must start pristine every build; this cache
# is supposed to survive across builds.
APT_CACHE_VOLUME := rpi-airplay-apt-cache

# Convenience aliases
image: build/rpi-airplay.img
uxplay: build/uxplay_debug
vendor-gstreamer: build/vendor-gstreamer/MANIFEST.md
base-image: build/dietpi-base.img

# --- UxPlay unit tests (tests/*.c) -- fully autonomous, no hardware/network ---
# `docker build` itself is the test runner: each test compiles and runs as
# part of a RUN line (see Dockerfile.unit-tests), so a non-zero exit (an
# assert() firing) fails the build. No -q: test PASS/FAIL output should be
# visible, not swallowed.
.PHONY: unit-tests
unit-tests: Dockerfile.unit-tests $(shell find UxPlay/tests UxPlay/lib/raop_conn_policy.* UxPlay/renderers/audio_renderer.c -type f 2>/dev/null)
	docker build -t unit-tests-buildtest -f Dockerfile.unit-tests .

# --- uxplay binary (native arm64 via colima/Docker) ---
build/uxplay_debug: Dockerfile.uxplay-buildtest $(shell find UxPlay -maxdepth 1)
	@mkdir -p build
	docker build -q -t uxplay-buildtest -f Dockerfile.uxplay-buildtest .
	id=$$(docker create uxplay-buildtest); \
	docker cp "$$id:/usr/local/bin/uxplay" build/uxplay_debug; \
	docker rm "$$id" >/dev/null

# --- vendor GStreamer closure ---
# Depends on a golden-reference package manifest to compute the delta
# against (see EXCLUDE-LIST.md / capture.sh) -- uses the most recent
# snapshot found under golden-reference/snapshots/.
LATEST_SNAPSHOT := $(shell ls -d golden-reference/snapshots/*/ 2>/dev/null | sort | tail -1)
build/vendor-gstreamer/MANIFEST.md: Dockerfile.gstreamer-closure tools/gstreamer-plugin-allowlist.txt tools/vendor-gstreamer-closure.sh
	@if [ -z "$(LATEST_SNAPSHOT)" ]; then \
	  echo "ERROR: no golden-reference snapshot found -- run 'make golden-reference' first" >&2; exit 1; \
	fi
	./tools/vendor-gstreamer-closure.sh "$(LATEST_SNAPSHOT)package-manifest.txt" build/vendor-gstreamer

# --- base DietPi image: our own pinned, versioned copy (see image-builder/BASE-IMAGE.env) ---
build/dietpi-base.img: image-builder/BASE-IMAGE.env image-builder/fetch-base.sh
	@mkdir -p build
	./image-builder/fetch-base.sh image-builder/BASE-IMAGE.env build/dietpi-base.img

# --- final image: extract base -> customize -> rebuild, all via image-builder ---
# Produces the raw .img directly, NOT compressed -- the only consumer of
# this artifact is `dd`ing it straight onto a card (or the local test
# harnesses below), and xz compression is pure wasted time on every single
# rebuild iteration for a file that's never actually downloaded/distributed
# in that form. See `image-xz` below if a compressed copy is ever actually
# needed (e.g. to archive/share a specific build).
build/rpi-airplay.img: build/uxplay_debug build/vendor-gstreamer/MANIFEST.md build/dietpi-base.img \
                          $(shell find provisioning/files -type f) provisioning/setup.sh \
                          image-builder/extract-partitions.sh image-builder/customize-root.sh \
                          image-builder/apt-packages.lock \
                          image-builder/customize-boot.sh \
                          image-builder/build-image.sh Dockerfile.image-builder \
                          $(PERSONAL_ENV)
	docker build -q -t $(IMAGE_BUILDER_TAG) -f Dockerfile.image-builder .
	docker volume rm -f $(DIETPI_ROOT_VOLUME) $(DIETPI_BOOT_VOLUME) >/dev/null 2>&1 || true
	docker run --rm \
	  -v "$$PWD/build":/build:ro \
	  -v "$$PWD/image-builder":/image-builder:ro \
	  -v $(DIETPI_BOOT_VOLUME):/dietpi-boot \
	  -v $(DIETPI_ROOT_VOLUME):/dietpi-root \
	  $(IMAGE_BUILDER_TAG) bash /image-builder/extract-partitions.sh \
	    /build/dietpi-base.img /dietpi-boot /dietpi-root
	docker run --rm \
	  -v $(DIETPI_ROOT_VOLUME):/rootdir \
	  -v "$$PWD/build/vendor-gstreamer":/vendor:ro \
	  -v "$$PWD/build/uxplay_debug":/uxplay_debug:ro \
	  -v "$$PWD/provisioning/files":/provfiles:ro \
	  -v "$$PWD/image-builder":/image-builder:ro \
	  -v $(APT_CACHE_VOLUME):/rootdir/var/cache/apt/archives \
	  $(if $(PERSONAL_ENV),-v "$$PWD/personal.env":/personal.env:ro,) \
	  $(IMAGE_BUILDER_TAG) bash /image-builder/customize-root.sh /rootdir /vendor /uxplay_debug /provfiles $(if $(PERSONAL_ENV),/personal.env,)
	docker run --rm \
	  -v $(DIETPI_BOOT_VOLUME):/dietpi-boot \
	  -v "$$PWD/image-builder":/image-builder:ro \
	  $(if $(PERSONAL_ENV),-v "$$PWD/personal.env":/personal.env:ro,) \
	  $(IMAGE_BUILDER_TAG) bash /image-builder/customize-boot.sh /dietpi-boot $(if $(PERSONAL_ENV),/personal.env,)
	docker run --rm \
	  -v "$$PWD":/work -w /work \
	  -v $(DIETPI_BOOT_VOLUME):/dietpi-boot \
	  -v $(DIETPI_ROOT_VOLUME):/dietpi-root \
	  $(IMAGE_BUILDER_TAG) bash image-builder/build-image.sh \
	    build/dietpi-base.img /dietpi-boot /dietpi-root build/rpi-airplay.img
	@echo "Built build/rpi-airplay.img"

# Rare, deliberate action -- compress (+ checksum) an already-built image,
# e.g. to archive or share a specific build. Never a dependency of routine
# targets (image/verify/test-boot/test-resize all use the raw .img and
# don't need a checksum sidecar -- make verify's own compare-rebuild.sh
# already computes its own sha256 of the built image for its report).
image-xz: build/rpi-airplay.img
	sha256sum build/rpi-airplay.img > build/rpi-airplay.img.sha256
	xz -f -k build/rpi-airplay.img
	sha256sum build/rpi-airplay.img.xz > build/rpi-airplay.img.xz.sha256
	@echo "Built build/rpi-airplay.img.xz"

# --- .PHONY targets: live-Pi-touching, always-rerun, or deliberate/rare actions ---
golden-reference:
	./golden-reference/capture.sh

verify: build/rpi-airplay.img
	./tools/compare-rebuild.sh build/rpi-airplay.img "$(LATEST_SNAPSHOT)"

reproducible-check:
	./tools/verify-reproducible-build.sh

# Deliberately NOT a dependency of build/dietpi-base.img -- run by hand,
# rarely, when actually adopting a newer DietPi release (see
# image-builder/BASE-IMAGE.env's own header comment).
refresh-base-image:
	./image-builder/refresh-base-image.sh

# Fast local functional check without an SD card: boots the built image's
# root filesystem via systemd-nspawn on colima's own VM (real aarch64 Linux,
# no emulation) and checks that services start and uxplay_debug gets as far
# as the real-hardware boundary (V4L2 decoder/VC4 GPU) cleanly. Does NOT
# replace Tier D -- no GPU/display/HDMI-audio/network-adapter emulation, so
# actual AirPlay sessions and hardware-decode performance still need the
# real Pi. See tools/nspawn-test-boot.sh for what's actually being checked.
test-boot: build/rpi-airplay.img
	colima ssh -- bash -c 'dpkg -s systemd-container >/dev/null 2>&1 || (sudo apt-get update -qq && sudo apt-get install -y -qq systemd-container)'
	colima ssh -- sudo bash -s -- < tools/nspawn-test-boot.sh

# Complements test-boot: nspawn never has a real block device backing its
# root filesystem, so DietPi's own first-boot partition/filesystem-resize
# service always takes its "container system" skip path there -- this
# loop-mounts the actual image via a real /dev/loopN and runs that resize
# script for real. See tools/loop-resize-test.sh for what this caught.
test-resize: build/rpi-airplay.img
	colima ssh -- bash -c 'dpkg -s parted util-linux >/dev/null 2>&1 || (sudo apt-get update -qq && sudo apt-get install -y -qq parted util-linux)'
	colima ssh -- sudo bash -s -- < tools/loop-resize-test.sh

clean:
	rm -rf build
	docker volume rm -f $(DIETPI_ROOT_VOLUME) $(DIETPI_BOOT_VOLUME) >/dev/null 2>&1 || true
