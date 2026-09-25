#!/bin/bash
# Substitutes personal.env values into an already-installed provisioned
# file, in place: a `# personal.env: KEY` marker line makes the assignment
# on the next line take its value from that key, when personal.env sets a
# non-empty one. The checked-in file under image-builder/files/ stays the
# only copy of the content -- this only rewrites marked values.
#
# Usage: image-builder/apply-personal-env.sh <personal-env-file> <target-file>
set -euo pipefail

personal_env="${1:?usage: $0 <personal-env-file> <target-file>}"
target="${2:?}"

# Export what personal.env assigns and read it back through awk's ENVIRON:
# awk's own -v processes backslash escapes in the value it is given, which
# would silently rewrite any value that legitimately contains a backslash.
set -a
# shellcheck disable=SC1090
. "$personal_env"
set +a

# A temporary outside the target's own directory, so a failed run cannot
# leave a stray file behind in the image; `cat >` keeps the target's
# existing mode and ownership.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
awk '
  /^# personal\.env: [A-Za-z_][A-Za-z0-9_]*$/ { key = $3; print; next }
  key != "" {
    if (!match($0, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
      printf "%s:%d: marker for %s does not precede an assignment\n", \
        FILENAME, FNR, key | "cat 1>&2"
      exit 1
    }
    if (ENVIRON[key] != "") {
      name = substr($0, 1, RLENGTH - 1)
      quote = (substr($0, RLENGTH + 1, 1) == "\"") ? "\"" : ""
      print name "=" quote ENVIRON[key] quote
      key = ""
      next
    }
    key = ""
  }
  { print }
' "$target" >"$tmp"
cat "$tmp" >"$target"
