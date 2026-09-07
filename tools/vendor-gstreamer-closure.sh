#!/bin/bash
# Computes the minimal GStreamer plugin closure this project needs and
# vendors it to build/vendor-gstreamer/, replacing the manual/unscripted
# extraction that originally produced vendor/gstreamer-1.0-arm64-trixie/.
#
# Approach: in a disposable environment with the FULL gstreamer-plugins-
# good/bad/base/libav/alsa closure installed (Dockerfile.gstreamer-closure),
# walk each allowlisted plugin's `ldd` closure (which is already the full
# transitive dependency set -- no manual recursion needed), then vendor only
# the files whose owning Debian package is NOT already going to be present
# on the target Pi (per a package manifest, e.g. golden-reference's).
#
# Two install locations matter and are kept separate:
#   plugins/ -> GStreamer plugin .so files (loaded from .../gstreamer-1.0/
#               specifically, by GStreamer's own plugin scanner)
#   libs/    -> general shared libraries those plugins link against
#               (e.g. libgstreamer-1.0.so.0, libv4l2.so.0) -- these live
#               directly under .../aarch64-linux-gnu/, NOT the plugin dir.
# A prior manual extraction only ever captured plugins/, silently missing
# libs/ -- which happened to already be present on the live Pi from an
# earlier, undocumented step, masking the gap. Don't repeat that mistake.
#
# Filenames use the SONAME (e.g. "libgstreamer-1.0.so.0"), not the further-
# versioned real filename (e.g. "libgstreamer-1.0.so.0.2602.0") -- that's
# what the dynamic linker actually looks up, and dpkg's file database
# indexes packages at that same soname-symlink level, so no separate
# symlink needs to be recreated at install time: the vendored file, named
# with the soname, already IS what ld.so is looking for.
#
# Usage: tools/vendor-gstreamer-closure.sh <target-package-manifest> [output-dir]
#   target-package-manifest: `dpkg --get-selections` output from the target
#                            (e.g. golden-reference/snapshots/<date>/package-manifest.txt)
#   output-dir: default build/vendor-gstreamer
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--in-container" ]; then
  # Re-invoked inside the container by the block below. $2 = manifest path
  # (bind-mounted), $3 = output dir (bind-mounted).
  manifest="$2"
  outdir="$3"
  allowlist="tools/gstreamer-plugin-allowlist.txt"

  # Resolve only the /lib -> /usr/lib usrmerge symlink (a single, well-known
  # Debian convention), not the full symlink chain -- keeps soname-level
  # filenames intact for both the vendored copy and the dpkg -S lookup
  # (verified: dpkg -S works fine on a soname symlink, no need to chase it
  # to the fully-versioned real file).
  normalize() { local p="$1"; echo "${p/#\/lib\//\/usr\/lib\/}"; }

  mkdir -p "$outdir/plugins" "$outdir/libs"
  declare -A vendor_files   # normalized soname-level path -> 1
  declare -A file_package   # normalized path -> package name

  plugin_paths=()
  while IFS= read -r name; do
    name="${name%%#*}"; name="$(echo -n "$name" | xargs)"
    [ -z "$name" ] && continue
    p=$(find /usr/lib -iname "$name" 2>/dev/null | head -1)
    if [ -z "$p" ]; then
      echo "ERROR: plugin $name not found in closure environment" >&2
      exit 1
    fi
    plugin_paths+=("$p")
  done < "$allowlist"

  scanner_path=$(find /usr -iname "gst-plugin-scanner" 2>/dev/null | head -1)
  all_paths=("${plugin_paths[@]}" "$scanner_path")

  for p in "${all_paths[@]}"; do
    vendor_files["$(normalize "$p")"]=1
    # ldd already resolves the FULL transitive closure, not just direct deps.
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      [ -e "$dep" ] || continue
      vendor_files["$(normalize "$dep")"]=1
    done < <(ldd "$p" 2>/dev/null | awk '/=>/{print $3} !/=>/ && /^[[:space:]]*\// {print $1}')
  done

  # Only keep files whose owning package isn't already on the target.
  # Ownership is checked against the FULLY resolved real file (chasing every
  # symlink, including Debian's update-alternatives indirection -- e.g.
  # libblas.so.3 -> /etc/alternatives/... -> the actual provider's real file),
  # not just the one-level-normalized soname path: dpkg -S doesn't see
  # through alternatives symlinks, so checking only the soname-level path
  # falsely flags alternatives-managed libraries (blas/lapack) as unowned
  # even when an equivalent provider package is already on the target.
  to_vendor=()
  for f in "${!vendor_files[@]}"; do
    [ -e "$f" ] || continue
    real=$(realpath "$f" 2>/dev/null || echo "$f")
    # dpkg -S output is "package[:arch]: /path" -- split on ": " (colon+space)
    # so a multiarch package's ":arch" qualifier stays intact (needed to match
    # `dpkg --get-selections` lines like "libc6:arm64\tinstall").
    owner=$(dpkg -S "$real" 2>/dev/null | head -1 | awk -F': ' '{print $1}' || true)
    if [ -z "$owner" ]; then
      # fall back to the soname-level path in case realpath overshot to
      # something dpkg doesn't index (rare, but cheap to also try)
      owner=$(dpkg -S "$f" 2>/dev/null | head -1 | awk -F': ' '{print $1}' || true)
    fi
    if [ -n "$owner" ] && grep -qP "^\Q$owner\E\s" "$manifest" 2>/dev/null; then
      continue  # already present on the target via an installed package
    fi
    to_vendor+=("$f")
    file_package["$f"]="${owner:-UNOWNED}"
  done

  {
    echo "# Auto-generated by tools/vendor-gstreamer-closure.sh -- do not edit by hand."
    echo "# dest, sha256, source package (as installed in this closure environment)"
    for f in "${to_vendor[@]}"; do
      base=$(basename "$f")
      if [[ "$f" == */gstreamer-1.0/* ]]; then
        dest="$outdir/plugins/$base"
        label="plugins/$base"
      else
        dest="$outdir/libs/$base"
        label="libs/$base"
      fi
      # -L: dereference: copy the real bytes, but name the copy after the
      # soname-level path, not the further-versioned real filename.
      cp -fL "$f" "$dest"
      sha=$(sha256sum "$dest" | cut -d' ' -f1)
      pkg="${file_package[$f]}"
      pkgver=""
      if [ "$pkg" != "UNOWNED" ]; then
        pkgver=$(dpkg -s "$pkg" 2>/dev/null | awk -F': ' '/^Version/{print $2}')
      fi
      echo "$label, $sha, ${pkg}${pkgver:+ $pkgver} (orig path: $f)"
    done
  } > "$outdir/MANIFEST.md.tmp"
  mv "$outdir/MANIFEST.md.tmp" "$outdir/MANIFEST.md"
  echo "Vendored ${#to_vendor[@]} files to $outdir"
  exit 0
fi

# --- outer (host) invocation ---
manifest="${1:?usage: $0 <target-package-manifest> [output-dir]}"
outdir="${2:-build/vendor-gstreamer}"
manifest_abs="$(cd "$(dirname "$manifest")" && pwd)/$(basename "$manifest")"
mkdir -p "$outdir"
outdir_abs="$(cd "$outdir" && pwd)"

docker build -q -t gstreamer-closure -f Dockerfile.gstreamer-closure . >/dev/null

docker run --rm \
  -v "$PWD":/work -w /work \
  -v "$manifest_abs":/tmp/target-manifest.txt:ro \
  -v "$outdir_abs":/tmp/out \
  gstreamer-closure \
  bash tools/vendor-gstreamer-closure.sh --in-container /tmp/target-manifest.txt /tmp/out
