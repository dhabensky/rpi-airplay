#!/bin/bash
# Prepares the pinned base DietPi image for image-builder/build-image.sh.
# The image itself lives under Git LFS at image-builder/dietpi-base/ (see
# refresh-base-image.sh) -- after a normal `git clone`/`git lfs pull` it's
# already on disk, so this just verifies its checksum and decompresses it.
# No network access needed for routine builds; only `make refresh-base-image`
# ever talks to dietpi.com.
#
# Usage: image-builder/fetch-base.sh <BASE-IMAGE.env> <out.img>
set -euo pipefail
cd "$(dirname "$0")/.."

env_file="${1:?usage: $0 <BASE-IMAGE.env> <out.img>}"
out="${2:?}"

if [ ! -f "$env_file" ]; then
  echo "ERROR: $env_file doesn't exist yet -- run 'make refresh-base-image' once" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$env_file"
: "${BASE_IMAGE_FILE:?BASE_IMAGE_FILE missing from $env_file -- run 'make refresh-base-image'}"

src="image-builder/dietpi-base/$BASE_IMAGE_FILE"
sha_file="$src.sha256"

if [ ! -f "$src" ]; then
  echo "ERROR: $src missing -- run 'git lfs pull' (or 'git lfs install' if this" >&2
  echo "  is a fresh clone and LFS wasn't set up yet)" >&2
  exit 1
fi

# A checked-out-but-unsmudged LFS pointer is a small text file starting
# with "version https://git-lfs...", not the real multi-hundred-MB blob --
# catch that explicitly rather than let a cryptic sha256 mismatch confuse
# whoever's building this.
if head -c 20 "$src" | grep -q "^version https://git-lfs"; then
  echo "==> $src is an LFS pointer, not the real file -- running 'git lfs pull'"
  git lfs pull --include="$src"
fi

echo "==> Verifying $src against $sha_file"
( cd image-builder/dietpi-base && sha256sum -c "$(basename "$sha_file")" )

echo "==> Decompressing to $out"
xz -dk "$src" -c > "$out"
echo "Base image ready: $out (DietPi ${BASE_IMAGE_DIETPI_VERSION:-unknown})"
