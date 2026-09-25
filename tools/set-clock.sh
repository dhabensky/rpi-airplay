#!/bin/bash
# Sets the Pi's clock from this host and persists it with fake-hwclock. The
# board has no RTC and, on the direct Ethernet link, no route to a time
# source, so its clock is whatever the last push left -- and journald stamps
# every record with it. Deliberately not part of tools/pissh: a plain
# connection must never silently change the device's clock.
#
# Usage: tools/set-clock.sh    (`make set-clock`, and `make deploy` runs it
# first). DRY_RUN=1 prints the plan and touches no network. The host's time is
# read just before the call, so the device lands within a round trip of it.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${DRY_RUN:-}" ]; then
  printf 'DRY_RUN set-clock\n  target %s\n  time   %s UTC\n' \
    "$(tools/pissh -t)" "$(date -u '+%Y-%m-%d %H:%M:%S')"
  exit 0
fi

host_epoch="$(date -u '+%s')"
tools/pissh -s <<EOF
set -euo pipefail
was="\$(date -u '+%Y-%m-%d %H:%M:%S')"
drift=\$(( \$(date -u '+%s') - $host_epoch ))
date -u -s "@$host_epoch" >/dev/null
/usr/sbin/fake-hwclock save
printf 'device clock was %s UTC (%+ds), now %s UTC; fake-hwclock.data: %s\n' \
  "\$was" "\$drift" "\$(date -u '+%Y-%m-%d %H:%M:%S')" "\$(cat /etc/fake-hwclock.data)"
EOF
