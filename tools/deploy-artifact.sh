#!/bin/bash
# Pushes one already-built binary to the Pi, checks the copy that landed
# there is byte-identical, and restarts the unit that runs it. The Makefile's
# deploy-* targets are the entry point and own the "is it stale" question --
# this script never builds anything.
#
# Usage: tools/deploy-artifact.sh <local-path> <remote-path> [unit]
# DRY_RUN=1 prints the plan and touches no network.
set -euo pipefail
cd "$(dirname "$0")/.."

local_path="${1:?usage: $0 <local-path> <remote-path> [unit]}"
remote_path="${2:?usage: $0 <local-path> <remote-path> [unit]}"
unit="${3:-}"

if [ ! -s "$local_path" ]; then
  echo "ERROR: nothing to deploy at $local_path" >&2
  exit 1
fi
local_sum="$(shasum -a 256 "$local_path" | cut -d' ' -f1)"

if [ -n "${DRY_RUN:-}" ]; then
  printf 'DRY_RUN %s\n  sha256   %s\n  target   %s:%s\n  restarts %s\n' \
    "$local_path" "$local_sum" "$(tools/pissh -t)" "$remote_path" "${unit:-nothing}"
  exit 0
fi

# An identical binary is already there: pushing it again would buy nothing and
# cost a restart, and restarting uxplay.service drops a live session.
remote_sum="$(tools/pissh "sha256sum $remote_path 2>/dev/null | cut -d' ' -f1" || true)"
if [ "$remote_sum" = "$local_sum" ]; then
  echo "$remote_path already at $local_sum -- nothing to do"
  exit 0
fi

# Staged beside the destination so installing it is a rename(2): the kernel
# refuses to overwrite the executable of a running process (ETXTBSY).
tools/pissh -p "$local_path" "$remote_path.new"
tools/pissh "chmod 0755 $remote_path.new && mv -f $remote_path.new $remote_path"

remote_sum="$(tools/pissh "sha256sum $remote_path | cut -d' ' -f1")"
if [ "$remote_sum" != "$local_sum" ]; then
  echo "ERROR: $remote_path is $remote_sum on the device, $local_sum here" >&2
  exit 1
fi
echo "deployed $remote_path sha256 $local_sum"

[ -n "$unit" ] || exit 0
tools/pissh -s <<EOF
systemctl restart $unit
for _ in \$(seq 1 20); do
  systemctl is-active --quiet $unit && exit 0
  sleep 0.25
done
systemctl status --no-pager -n 20 $unit
exit 1
EOF
echo "restarted $unit"
