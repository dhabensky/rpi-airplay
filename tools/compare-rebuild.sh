#!/bin/bash
# Tiered comparison of a built image against a golden-reference snapshot.
# Tiers A-C are checked directly against the built image's extracted
# partitions (no boot needed, no loop-mount -- see image-builder's "No
# privileged containers" rationale). Tier D (functional smoke test) and
# Tier E (raw disk bit-diff) are NOT implemented here by design -- see
# REBUILD-STATUS.md's per-run notes for why.
#
# Usage: tools/compare-rebuild.sh <built.img> <golden-reference-snapshot-dir>
set -euo pipefail
cd "$(dirname "$0")/.."

built_img="${1:?usage: $0 <built.img> <golden-reference-snapshot-dir>}"
golden="${2:?}"

if [ "${1:-}" = "--in-container" ]; then
  built_img="$2"; golden="$3"; work="$4"
  mkdir -p "$work/root" "$work/boot"
  bash image-builder/extract-partitions.sh "$built_img" "$work/boot" "$work/root" >&2

  echo "=== TIER A: package manifest ==="
  dpkg --root="$work/root" --get-selections | sort > "$work/candidate-packages.txt"
  sort "$golden/package-manifest.txt" > "$work/golden-packages.txt"
  if diff -q "$work/golden-packages.txt" "$work/candidate-packages.txt" >/dev/null; then
    echo "PASS: package selections identical"
  else
    echo "DIFF: package selections differ (- golden, + candidate):"
    diff "$work/golden-packages.txt" "$work/candidate-packages.txt" | head -50 || true
  fi

  echo
  echo "=== TIER B: file-tree content (root partition, minus EXCLUDE-LIST.md) ==="
  exclude_expr=()
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    exclude_expr+=(-not -path "${work}/root${pattern}")
  done < <(sed -n '/^```$/,/^```$/p' golden-reference/EXCLUDE-LIST.md | sed '1d;$d')
  ( cd "$work/root" && find . -type f "${exclude_expr[@]/${work}\/root/.}" -exec sha256sum {} + 2>/dev/null | sort -k2 ) \
    > "$work/candidate-filetree.sha256" || true
  # Normalize golden's absolute paths (/etc/foo) to the same relative-path
  # basis (./etc/foo) used above, so the two are comparable.
  sed -E 's#^([0-9a-f]+)  /#\1  ./#' "$golden/filetree-manifest.sha256" | sort -k2 > "$work/golden-filetree.sha256"
  # Compare only paths present in BOTH manifests -- paths unique to one side
  # (e.g. a package version bump adding/removing a file) are reported
  # separately from actual content mismatches on shared paths.
  join -j2 -o 1.1,2.1,0 <(sort -k2 "$work/golden-filetree.sha256") <(sort -k2 "$work/candidate-filetree.sha256") \
    | awk '{if ($1!=$2) print}' > "$work/tierb-mismatches.txt" || true
  mismatch_count=$(wc -l < "$work/tierb-mismatches.txt" | tr -d ' ')
  golden_only=$(comm -23 <(awk '{print $2}' "$work/golden-filetree.sha256" | sort) <(awk '{print $2}' "$work/candidate-filetree.sha256" | sort) | wc -l | tr -d ' ')
  candidate_only=$(comm -13 <(awk '{print $2}' "$work/golden-filetree.sha256" | sort) <(awk '{print $2}' "$work/candidate-filetree.sha256" | sort) | wc -l | tr -d ' ')
  if [ "$mismatch_count" = "0" ]; then
    echo "PASS: all $(wc -l < "$work/candidate-filetree.sha256" | tr -d ' ') shared files match content"
  else
    echo "DIFF: $mismatch_count files differ in content on shared paths (see build/compare-tierb-mismatches.txt)"
    cp "$work/tierb-mismatches.txt" build/compare-tierb-mismatches.txt
  fi
  echo "  (golden-only paths: $golden_only, candidate-only paths: $candidate_only -- expected for routine"
  echo "   package version bumps; see REBUILD-STATUS.md accepted-delta notes, not auto-failed here)"

  echo
  echo "=== TIER B (boot partition, minus known macOS-mount junk) ==="
  # Previously never checked at all -- config.txt/cmdline.txt/dietpi.txt
  # customizations that were only ever hand-applied on the live Pi (never
  # scripted) went completely unnoticed here for the whole project until
  # caught by an actual real-hardware boot. golden's own boot manifest
  # includes .Spotlight-V100/.fseventsd/etc. from an earlier Mac-mount of
  # this same card (see README's flashing section) -- filtered inline here
  # rather than folding boot-partition paths into EXCLUDE-LIST.md's
  # root-partition-scoped, absolute-path format.
  ( cd "$work/boot" && find . -type f \
      -not -path './.Spotlight-V100/*' -not -path './.fseventsd/*' \
      -not -path './.Trashes/*' -not -name '.DS_Store' -not -name '._*' \
      -exec sha256sum {} + 2>/dev/null | sort -k2 ) \
    > "$work/candidate-boot-filetree.sha256" || true
  sed -E 's#^([0-9a-f]+)  /boot/firmware/#\1  ./#' "$golden/filetree-manifest-boot.sha256" \
    | grep -Ev '  \./(\.Spotlight-V100|\.fseventsd|\.Trashes)/|  \./(\.DS_Store|\._)' \
    | sort -k2 > "$work/golden-boot-filetree.sha256"
  join -j2 -o 1.1,2.1,0 <(sort -k2 "$work/golden-boot-filetree.sha256") <(sort -k2 "$work/candidate-boot-filetree.sha256") \
    | awk '{if ($1!=$2) print}' > "$work/tierb-boot-mismatches.txt" || true
  boot_mismatch_count=$(wc -l < "$work/tierb-boot-mismatches.txt" | tr -d ' ')
  boot_golden_only=$(comm -23 <(awk '{print $2}' "$work/golden-boot-filetree.sha256" | sort) <(awk '{print $2}' "$work/candidate-boot-filetree.sha256" | sort) | wc -l | tr -d ' ')
  boot_candidate_only=$(comm -13 <(awk '{print $2}' "$work/golden-boot-filetree.sha256" | sort) <(awk '{print $2}' "$work/candidate-boot-filetree.sha256" | sort) | wc -l | tr -d ' ')
  if [ "$boot_mismatch_count" = "0" ]; then
    echo "PASS: all $(wc -l < "$work/candidate-boot-filetree.sha256" | tr -d ' ') shared boot files match content"
  else
    echo "DIFF: $boot_mismatch_count boot files differ in content on shared paths:"
    while IFS=' ' read -r _ _ path; do echo "  $path"; done < "$work/tierb-boot-mismatches.txt"
    cp "$work/tierb-boot-mismatches.txt" build/compare-tierb-boot-mismatches.txt
  fi
  echo "  (golden-only paths: $boot_golden_only, candidate-only paths: $boot_candidate_only)"

  echo
  echo "=== TIER C: binary-exact (uxplay_debug + vendor GStreamer) ==="
  cand_uxplay_sha=$(sha256sum "$work/root/usr/local/bin/uxplay_debug" | cut -d' ' -f1)
  golden_uxplay_sha=$(awk '{print $1}' "$golden/uxplay_debug.sha256")
  if [ "$cand_uxplay_sha" = "$golden_uxplay_sha" ]; then
    echo "PASS: uxplay_debug binary matches golden reference exactly"
  else
    echo "DIFF: uxplay_debug differs (golden=$golden_uxplay_sha candidate=$cand_uxplay_sha) --"
    echo "  expected ONLY if the UxPlay submodule commit changed since the golden capture;"
    echo "  a mismatch against a build of the SAME commit is a real reproducibility bug."
  fi
  vendor_fail=0
  for f in vendor/gstreamer-1.0-arm64-trixie/plugins/*.so vendor/gstreamer-1.0-arm64-trixie/libs/*; do
    base=$(basename "$f")
    target="$work/root/usr/lib/aarch64-linux-gnu/gstreamer-1.0/$base"
    [ -f "$target" ] || target="$work/root/usr/lib/aarch64-linux-gnu/$base"
    if [ ! -f "$target" ]; then echo "DIFF: $base missing from built image"; vendor_fail=1; continue; fi
    [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$(sha256sum "$target" | cut -d' ' -f1)" ] || { echo "DIFF: $base content differs"; vendor_fail=1; }
  done
  [ "$vendor_fail" = "0" ] && echo "PASS: all vendored GStreamer files match exactly"

  echo
  echo "=== TIER D: functional smoke test ==="
  echo "BLOCKED: no spare SD card/Pi available for a real flash+boot+AirPlay test (see plan)."
  echo
  echo "=== TIER E: raw disk bit-diff ==="
  echo "N/A by design: the .img is the deliverable, not a byte-diff target (see plan's reframing)."
  exit 0
fi

# --- outer (host) invocation ---
mkdir -p build
docker build -q -t rpi-airplay-image-builder -f Dockerfile.image-builder . >/dev/null
golden_abs="$(cd "$golden" && pwd)"
built_abs="$(cd "$(dirname "$built_img")" && pwd)/$(basename "$built_img")"

result=$(docker run --rm \
  -v "$PWD":/work -w /work \
  -v "$golden_abs":/golden:ro \
  -v "$built_abs":/built.img:ro \
  rpi-airplay-image-builder \
  bash tools/compare-rebuild.sh --in-container /built.img /golden /tmp/compare-work 2>&1) || true

echo "$result"

{
  echo
  echo "## $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- golden-reference snapshot: \`$golden\`"
  echo "- built image: \`$built_img\` ($(sha256sum "$built_img" 2>/dev/null | cut -d' ' -f1 | head -c12)...)"
  echo "- UxPlay submodule commit: \`$(git -C UxPlay rev-parse --short HEAD 2>/dev/null || echo unknown)\`"
  echo '```'
  echo "$result"
  echo '```'
} >> REBUILD-STATUS.md

echo
echo "==> Appended to REBUILD-STATUS.md"
