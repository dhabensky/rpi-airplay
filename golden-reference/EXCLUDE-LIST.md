# Volatile / host-identity paths excluded from file-tree comparison

Consumed by both `capture.sh` (skip when hashing) and the future
`tools/compare-rebuild.sh` (skip when diffing) — kept as a single list so
the two never drift apart. These are inherently unique per install or
per-boot and will legitimately differ between the live Pi and any rebuild,
even a perfect one; diffing them would just be noise.

```
/etc/machine-id
/var/lib/dbus/machine-id
/etc/ssh/ssh_host_*_key*
/var/log/*
/var/cache/*
/var/lib/apt/lists/*
/root/.bash_history
/home/*/.bash_history
/home/*/.cache/*
/tmp/*
/var/tmp/*
/run/*
/var/lib/systemd/random-seed
/var/lib/systemd/timers/*
/var/lib/dhcp/*
/home/uxplay/core
/etc/wpa_supplicant/wpa_supplicant.conf
```

`/proc`, `/sys`, `/dev` aren't in this list because `find -xdev` (used by
`capture.sh`) never descends into other filesystems from `/` in the first
place — they don't need an explicit exclude.

The WiFi config (`/etc/wpa_supplicant/wpa_supplicant.conf`) holds this
network's PSK — it's excluded from the file-tree walk entirely and handled
separately: `capture.sh` records only its sha256 (to detect if it changes)
plus a PSK-redacted template, never the verbatim file.
