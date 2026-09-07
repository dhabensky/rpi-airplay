#!/bin/bash
# Downloads and verifies our own pinned copy of the base DietPi image (see
# image-builder/BASE-IMAGE.env / refresh-base-image.sh for how that pin was
# established). No dependency on dietpi.com's mutable download page for
# routine builds -- only `make refresh-base-image` ever touches that.
#
# Usage: image-builder/fetch-base.sh <BASE-IMAGE.env> <out.img>
set -euo pipefail
cd "$(dirname "$0")/.."

env_file="${1:?usage: $0 <BASE-IMAGE.env> <out.img>}"
out="${2:?}"

if [ ! -f "$env_file" ]; then
  echo "ERROR: $env_file doesn't exist yet -- run 'make refresh-base-image' once" >&2
  echo "  (requires gh auth login; see image-builder/refresh-base-image.sh)" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$env_file"
: "${BASE_IMAGE_URL:?BASE_IMAGE_URL missing from $env_file}"
: "${BASE_IMAGE_SHA256:?BASE_IMAGE_SHA256 missing from $env_file}"

cache="build/.cache/$(basename "$BASE_IMAGE_URL")"
mkdir -p "$(dirname "$cache")"

if [ -f "$cache" ] && echo "$BASE_IMAGE_SHA256  $cache" | sha256sum -c - >/dev/null 2>&1; then
  echo "==> Using cached, already-verified $cache"
else
  echo "==> Downloading $BASE_IMAGE_URL"
  curl -sSL -o "$cache.tmp" "$BASE_IMAGE_URL"
  echo "$BASE_IMAGE_SHA256  $cache.tmp" | sha256sum -c -
  mv "$cache.tmp" "$cache"
fi

echo "==> Decompressing to $out"
xz -dk "$cache" -c > "$out"
echo "Base image ready: $out (DietPi ${BASE_IMAGE_DIETPI_VERSION:-unknown})"
