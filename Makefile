# Build system for rpi-airplay -- see the plan/README for the full
# rationale. `make image` produces a complete, ready-to-flash .img from a
# clean checkout; `make verify` checks it against a golden-reference
# capture from the live Pi. Everything here calls into plain shell/Docker
# recipes under tools/ and image-builder/ -- this file is the dependency
# graph and the one documented entry point, not where the actual logic
# lives.
.PHONY: image image-xz uxplay menu-render uxplay-menu log-ts drmdump synthetic-client \
        vendor-gstreamer base-image golden-reference verify \
        reproducible-check refresh-base-image refresh-apt-lists refresh-buildenv-apt-lists \
        test-boot test-eth-backup test-resize clean

# One shared tooling image (see Dockerfile's own header) for every
# disposable build/test/tool environment this project uses.
BUILDENV_TAG := rpi-airplay-buildenv

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
menu-render: build/bin/menu-render
uxplay-menu: build/bin/uxplay-menu
log-ts: build/bin/log-ts
drmdump: build/bin/drmdump
synthetic-client: build/synthetic-client
vendor-gstreamer: build/vendor-gstreamer/MANIFEST.md
base-image: build/dietpi-base.img

# --- UxPlay unit tests (tests/*.c) -- fully autonomous, no hardware/network ---
# tools/run-unit-tests.sh is the test runner: each test compiles and runs
# inside the container, so a non-zero exit (an assert() firing) fails this
# recipe.
.PHONY: unit-tests
unit-tests: Dockerfile $(shell find apt-lists -type f 2>/dev/null) $(shell find UxPlay/tests UxPlay/lib/raop_conn_policy.* UxPlay/renderers/audio_renderer.c tools/tests tools/uxplay-menu-parse.c tools/uxplay-menu-parse.h -type f 2>/dev/null)
	./tools/run-unit-tests.sh

# --- tools/pytest/ e2e suite ---
# Bootstraps the venv (idempotent) and runs the suite. The default selection
# leaves out the tests that need the live device; `make pytest PYTEST_MARK=`
# runs those too, PYTEST_ARGS passes anything else through (-v, -k, a path).
PYTEST_MARK ?= not pi_hardware
PYTEST_ARGS ?=
.PHONY: pytest
pytest:
	./tools/pytest-setup.sh
	tools/pytest/.venv/bin/pytest tools/pytest/ $(if $(PYTEST_MARK),-m "$(PYTEST_MARK)",) $(PYTEST_ARGS)

# --- uxplay binary (native arm64 via colima/Docker) ---
# UxPlay/.git's mtime moves on any ordinary git command (measured: a plain
# `git status` advanced it), which made every build stale; the submodule's
# checked-out ref is tracked through .git/HEAD instead.
UXPLAY_PREREQS := $(filter-out UxPlay/.git,$(shell find UxPlay -maxdepth 1)) $(wildcard UxPlay/.git/HEAD)
build/uxplay_debug: Dockerfile $(shell find apt-lists -type f 2>/dev/null) $(UXPLAY_PREREQS)
	./tools/build-uxplay.sh build/uxplay_debug

# --- synthetic-client binary: the same build-uxplay.sh run that produces
# build/uxplay_debug writes this one too, so re-run that build only when this
# copy is missing or older -- that run truncates both, so it cannot be stale.
build/synthetic-client: build/uxplay_debug
	@{ [ -s $@ ] && [ ! $@ -ot $< ]; } || ./tools/build-uxplay.sh build/uxplay_debug
	@./tools/check-build-artifact.sh $@

# --- menu-render binary (native arm64 via colima/Docker) ---
# Each of these rules asserts its own product: the build scripts mount an
# output directory, so a path the Docker VM doesn't share leaves nothing here.
build/bin/menu-render: Dockerfile $(shell find apt-lists -type f 2>/dev/null) tools/menu-render.c tools/build-menu-render.sh
	./tools/build-menu-render.sh build/bin
	@./tools/check-build-artifact.sh $@

# --- uxplay-menu binary (native arm64 via colima/Docker) ---
build/bin/uxplay-menu: Dockerfile $(shell find apt-lists -type f 2>/dev/null) tools/uxplay-menu.c tools/uxplay-menu-parse.c tools/uxplay-menu-parse.h tools/build-uxplay-menu.sh
	./tools/build-uxplay-menu.sh build/bin
	@./tools/check-build-artifact.sh $@

# --- log-ts binary (native arm64 via colima/Docker) ---
build/bin/log-ts: Dockerfile $(shell find apt-lists -type f 2>/dev/null) tools/log-ts.c tools/build-log-ts.sh
	./tools/build-log-ts.sh build/bin
	@./tools/check-build-artifact.sh $@

# --- drmdump binary (native arm64 via colima/Docker; build-drmdump.sh
# also produces drmpaint, which is not shipped) ---
build/bin/drmdump: Dockerfile $(shell find apt-lists -type f 2>/dev/null) tools/drmdump.c tools/drmpaint.c tools/build-drmdump.sh
	./tools/build-drmdump.sh build/bin
	@./tools/check-build-artifact.sh $@

# --- vendor GStreamer closure ---
# Depends on a golden-reference package manifest to compute the delta
# against (see EXCLUDE-LIST.md / capture.sh) -- uses the most recent
# snapshot found under golden-reference/snapshots/.
LATEST_SNAPSHOT := $(shell ls -d golden-reference/snapshots/*/ 2>/dev/null | sort | tail -1)
build/vendor-gstreamer/MANIFEST.md: Dockerfile $(shell find apt-lists -type f 2>/dev/null) tools/gstreamer-plugin-allowlist.txt tools/vendor-gstreamer-closure.sh
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
build/rpi-airplay.img: build/uxplay_debug build/bin/menu-render build/bin/uxplay-menu build/bin/log-ts \
                          build/bin/drmdump build/synthetic-client \
                          build/vendor-gstreamer/MANIFEST.md build/dietpi-base.img \
                          $(shell find image-builder/files -type f) \
                          image-builder/extract-partitions.sh image-builder/customize-root.sh \
                          image-builder/apt-packages.lock $(shell find image-builder/apt-lists -type f) \
                          image-builder/customize-boot.sh \
                          image-builder/build-image.sh Dockerfile \
                          $(shell find apt-lists -type f 2>/dev/null) \
                          $(PERSONAL_ENV)
	docker build -q -t $(BUILDENV_TAG) -f Dockerfile .
	docker volume rm -f $(DIETPI_ROOT_VOLUME) $(DIETPI_BOOT_VOLUME) >/dev/null 2>&1 || true
	docker run --rm \
	  -v "$$PWD/build":/build:ro \
	  -v "$$PWD/image-builder":/image-builder:ro \
	  -v $(DIETPI_BOOT_VOLUME):/dietpi-boot \
	  -v $(DIETPI_ROOT_VOLUME):/dietpi-root \
	  $(BUILDENV_TAG) bash /image-builder/extract-partitions.sh \
	    /build/dietpi-base.img /dietpi-boot /dietpi-root
	docker run --rm \
	  -v $(DIETPI_ROOT_VOLUME):/rootdir \
	  -v "$$PWD/build/vendor-gstreamer":/vendor:ro \
	  -v "$$PWD/build/uxplay_debug":/uxplay_debug:ro \
	  -v "$$PWD/build/bin/menu-render":/menu-render:ro \
	  -v "$$PWD/build/bin/uxplay-menu":/uxplay-menu:ro \
	  -v "$$PWD/build/bin/log-ts":/log-ts:ro \
	  -v "$$PWD/build/bin/drmdump":/drmdump:ro \
	  -v "$$PWD/build/synthetic-client":/synthetic-client:ro \
	  -v "$$PWD/image-builder/files":/provfiles:ro \
	  -v "$$PWD/image-builder":/image-builder:ro \
	  -v $(APT_CACHE_VOLUME):/rootdir/var/cache/apt/archives \
	  $(if $(PERSONAL_ENV),-v "$$PWD/personal.env":/personal.env:ro,) \
	  $(BUILDENV_TAG) bash /image-builder/customize-root.sh /rootdir /vendor /uxplay_debug /menu-render /log-ts /drmdump /synthetic-client /uxplay-menu /provfiles $(if $(PERSONAL_ENV),/personal.env,)
	docker run --rm \
	  -v $(DIETPI_BOOT_VOLUME):/dietpi-boot \
	  -v "$$PWD/image-builder":/image-builder:ro \
	  $(if $(PERSONAL_ENV),-v "$$PWD/personal.env":/personal.env:ro,) \
	  $(BUILDENV_TAG) bash /image-builder/customize-boot.sh /dietpi-boot $(if $(PERSONAL_ENV),/personal.env,)
	docker run --rm \
	  -v "$$PWD":/work -w /work \
	  -v $(DIETPI_BOOT_VOLUME):/dietpi-boot \
	  -v $(DIETPI_ROOT_VOLUME):/dietpi-root \
	  $(BUILDENV_TAG) bash image-builder/build-image.sh \
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

# --- deploying to the already-provisioned live Pi (tools/pissh's target) ---
# The fast path for iterating without a reflash. Each target builds through
# the file target above, so staleness is decided in one place, and restarts
# only the unit that actually runs that binary.
#
# `make deploy` pushes everything the image ships; the per-artifact targets
# are for a single binary (deploy-uxplay-menu is the common one). A push whose
# sha256 already matches the device is skipped, restart included.
# DRY_RUN=1 prints each plan and touches no network.
.PHONY: deploy deploy-uxplay deploy-uxplay-menu deploy-menu-render deploy-log-ts \
        deploy-drmdump deploy-synthetic-client
export DRY_RUN

# The two that restart a unit come last, so the units come back up against a
# fully updated set of binaries.
deploy: deploy-menu-render deploy-drmdump deploy-synthetic-client \
        deploy-uxplay-menu deploy-log-ts deploy-uxplay

deploy-uxplay: build/uxplay_debug
	./tools/deploy-artifact.sh $< /usr/local/bin/uxplay_debug uxplay.service

# log-ts is uxplay.service's ExecStart (it runs uxplay_debug), so a new one
# only takes effect when that unit restarts.
deploy-log-ts: build/bin/log-ts
	./tools/deploy-artifact.sh $< /usr/local/bin/log-ts uxplay.service

deploy-uxplay-menu: build/bin/uxplay-menu
	./tools/deploy-artifact.sh $< /usr/local/bin/uxplay-menu uxplay-menu.service

# menu-render is exec'd per repaint, drmdump and synthetic-client are run by
# hand: nothing resident to restart.
deploy-menu-render: build/bin/menu-render
	./tools/deploy-artifact.sh $< /usr/local/bin/menu-render

deploy-drmdump: build/bin/drmdump
	./tools/deploy-artifact.sh $< /usr/local/bin/drmdump

deploy-synthetic-client: build/synthetic-client
	./tools/deploy-artifact.sh $< /usr/local/bin/synthetic-client

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

# Deliberate, rare action (see that script's header) -- run this, then
# regenerate image-builder/apt-packages.lock from the same apt-get update
# snapshot, whenever you actually want package versions to move.
refresh-apt-lists: base-image
	./image-builder/refresh-apt-lists.sh

# Same fix, for the shared Dockerfile's own build-tooling packages instead
# of the shipped Pi image's (see that script's header).
refresh-buildenv-apt-lists:
	./tools/refresh-buildenv-apt-lists.sh

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

# eth0's 169.254.100.1/16 backup address under nspawn with veths named
# eth0/wlan0 (see tools/nspawn-test-eth-backup.sh for the cases covered).
test-eth-backup: build/rpi-airplay.img
	colima ssh -- bash -c 'dpkg -s systemd-container dnsmasq-base >/dev/null 2>&1 || (sudo apt-get update -qq && sudo apt-get install -y -qq systemd-container dnsmasq-base)'
	colima ssh -- sudo bash -s -- < tools/nspawn-test-eth-backup.sh

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
