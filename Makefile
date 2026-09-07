# Build system for rpi-airplay -- see the plan/README for the full
# rationale. `make image` produces a complete, ready-to-flash .img from a
# clean checkout; `make verify` checks it against a golden-reference
# capture from the live Pi. Everything here calls into plain shell/Docker
# recipes under tools/ and image-builder/ -- this file is the dependency
# graph and the one documented entry point, not where the actual logic
# lives.
.PHONY: image uxplay vendor-gstreamer base-image golden-reference verify \
        reproducible-check refresh-base-image clean

IMAGE_BUILDER_TAG := rpi-airplay-image-builder
GSTREAMER_CLOSURE_TAG := rpi-airplay-gstreamer-closure

# Convenience aliases
image: build/rpi-airplay.img.xz
uxplay: build/uxplay_debug
vendor-gstreamer: build/vendor-gstreamer/MANIFEST.md
base-image: build/dietpi-base.img

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
build/rpi-airplay.img.xz: build/uxplay_debug build/vendor-gstreamer/MANIFEST.md build/dietpi-base.img \
                          $(shell find provisioning/files -type f) provisioning/setup.sh \
                          image-builder/extract-partitions.sh image-builder/customize-root.sh \
                          image-builder/build-image.sh Dockerfile.image-builder
	docker build -q -t $(IMAGE_BUILDER_TAG) -f Dockerfile.image-builder .
	rm -rf build/dietpi-root build/dietpi-boot
	docker run --rm \
	  -v "$$PWD":/work -w /work \
	  $(IMAGE_BUILDER_TAG) bash image-builder/extract-partitions.sh \
	    build/dietpi-base.img build/dietpi-boot build/dietpi-root
	docker run --rm \
	  -v "$$PWD/build/dietpi-root":/rootdir \
	  -v "$$PWD/build/vendor-gstreamer":/vendor:ro \
	  -v "$$PWD/build/uxplay_debug":/uxplay_debug:ro \
	  -v "$$PWD/provisioning/files":/provfiles:ro \
	  -v "$$PWD/image-builder":/image-builder:ro \
	  $(IMAGE_BUILDER_TAG) bash /image-builder/customize-root.sh /rootdir /vendor /uxplay_debug /provfiles
	docker run --rm \
	  -v "$$PWD":/work -w /work \
	  $(IMAGE_BUILDER_TAG) bash image-builder/build-image.sh \
	    build/dietpi-base.img build/dietpi-boot build/dietpi-root build/rpi-airplay.img
	xz -f -k build/rpi-airplay.img
	sha256sum build/rpi-airplay.img.xz > build/rpi-airplay.img.xz.sha256
	@echo "Built build/rpi-airplay.img.xz"

# --- .PHONY targets: live-Pi-touching, always-rerun, or deliberate/rare actions ---
golden-reference:
	./golden-reference/capture.sh

verify: build/rpi-airplay.img.xz
	./tools/compare-rebuild.sh build/rpi-airplay.img "$(LATEST_SNAPSHOT)"

reproducible-check:
	./tools/verify-reproducible-build.sh

# Deliberately NOT a dependency of build/dietpi-base.img -- run by hand,
# rarely, when actually adopting a newer DietPi release (see
# image-builder/BASE-IMAGE.env's own header comment).
refresh-base-image:
	./image-builder/refresh-base-image.sh

clean:
	rm -rf build
