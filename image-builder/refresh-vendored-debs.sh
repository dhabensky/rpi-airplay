#!/bin/bash
# Deliberate, rare action (run by hand, never automatic): downloads the
# exact .deb files for every image-builder/apt-packages.lock entry that
# resolves from archive.raspberrypi.com (identified by cross-referencing
# the lock file's package=version pins against that source's own frozen
# Packages index in image-builder/apt-lists/ -- not guessed, read
# directly from the same index customize-root.sh already trusts), and
# writes them into image-builder/vendored-debs/.
#
# Why: freezing the apt INDEX (image-builder/apt-lists/) pins which
# version resolves, but apt-get install still downloads the actual .deb
# BYTES from the live host at build time. dietpi.com and
# archive.raspberrypi.com are far less durable than Debian's own
# archive -- if either ever prunes an old file or goes down, a pinned
# version that still resolves in the frozen index becomes undownloadable
# anyway. Cross-referencing every apt-packages.lock entry against each
# source's frozen index (2026-09-14) found 0 packages resolving from
# dietpi.com and 27 from archive.raspberrypi.com (~35MB) -- this script
# vendors exactly those 27, nothing else. Debian's own repos are left
# live/frozen-index-only, matching the project's own call that they're
# reliable enough not to need this.
#
# Every downloaded file's SHA256 is verified against the frozen index
# before being accepted -- this script trusts the already-reviewed,
# already-committed index for integrity, not whatever the network
# happens to hand back.
#
# Does NOT commit -- review and commit image-builder/vendored-debs/
# explicitly, same convention as refresh-apt-lists.sh.
#
# Usage: image-builder/refresh-vendored-debs.sh
set -euo pipefail
cd "$(dirname "$0")/.."

LOCKFILE="image-builder/apt-packages.lock"
RASPI_PACKAGES_XZ="image-builder/apt-lists/archive.raspberrypi.com_debian_dists_trixie_main_binary-arm64_Packages.xz"
OUTDIR="image-builder/vendored-debs"
BASE_URL="https://archive.raspberrypi.com/debian/"

if [ ! -f "$RASPI_PACKAGES_XZ" ]; then
  echo "ERROR: $RASPI_PACKAGES_XZ not found -- run 'make refresh-apt-lists' first" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

echo "==> Cross-referencing $LOCKFILE against $RASPI_PACKAGES_XZ"
python3 - "$LOCKFILE" "$RASPI_PACKAGES_XZ" "$OUTDIR" "$BASE_URL" <<'PYEOF'
import lzma, subprocess, sys, hashlib, urllib.request, os

lockfile, packages_xz, outdir, base_url = sys.argv[1:5]

def parse_packages(data):
    entries = {}
    name = version = fname = sha256 = size = None
    for line in data.decode("utf-8", errors="replace").split("\n"):
        line = line.rstrip("\r")
        if line.startswith("Package: "):
            name = line[len("Package: "):]
        elif line.startswith("Version: "):
            version = line[len("Version: "):]
        elif line.startswith("Filename: "):
            fname = line[len("Filename: "):]
        elif line.startswith("SHA256: "):
            sha256 = line[len("SHA256: "):]
        elif line.startswith("Size: "):
            size = int(line[len("Size: "):])
        elif line == "":
            if name and version:
                entries[(name, version)] = (fname, sha256, size)
            name = version = fname = sha256 = size = None
    return entries

with open(packages_xz, "rb") as f:
    raspi_index = parse_packages(lzma.decompress(f.read()))

lock_pkgs = []
with open(lockfile) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, version = line.split("=", 1)
        lock_pkgs.append((name, version))

to_fetch = [(n, v, *raspi_index[(n, v)]) for n, v in lock_pkgs if (n, v) in raspi_index]
print(f"{len(to_fetch)} of {len(lock_pkgs)} lock entries resolve from archive.raspberrypi.com")

for name, version, fname, sha256_expected, size in to_fetch:
    basename = os.path.basename(fname)
    outpath = os.path.join(outdir, basename)
    if os.path.exists(outpath):
        with open(outpath, "rb") as f:
            actual = hashlib.sha256(f.read()).hexdigest()
        if actual == sha256_expected:
            print(f"  {basename}: already present, SHA256 OK, skipping")
            continue
        print(f"  {basename}: present but SHA256 mismatch, re-downloading")

    url = base_url + fname
    print(f"  {basename}: downloading from {url}")
    urllib.request.urlretrieve(url, outpath)

    with open(outpath, "rb") as f:
        data = f.read()
    actual_sha256 = hashlib.sha256(data).hexdigest()
    actual_size = len(data)
    if actual_sha256 != sha256_expected or actual_size != size:
        os.remove(outpath)
        print(f"ERROR: {basename} failed verification "
              f"(sha256 expected={sha256_expected} got={actual_sha256}, "
              f"size expected={size} got={actual_size})", file=sys.stderr)
        sys.exit(1)
    print(f"    OK ({actual_size} bytes, SHA256 verified)")

print(f"\nDone: {len(to_fetch)} files in {outdir}/")
PYEOF

echo "==> $(ls "$OUTDIR" | wc -l | tr -d ' ') files, $(du -sh "$OUTDIR" | cut -f1) total"
echo "    Review and commit: git add $OUTDIR"
