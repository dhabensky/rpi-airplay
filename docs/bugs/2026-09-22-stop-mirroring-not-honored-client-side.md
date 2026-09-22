# "Stop Mirroring" leaves the session running (macOS-side, not UxPlay)

Status: **NOT OUR BUG — closed with wire-level proof (2026-09-22).** The
receiver behaves correctly throughout; macOS turns its own mirroring UI
off without tearing the session down. No server-side fix is possible;
the workaround is documented below.

## Symptom

Pressing "Stop Mirroring" in the Mac's Control Center switches the UI
off, but the TV keeps showing the live Mac screen. Reported repeatedly
over 2026-09-13..21 as "mirroring failed to finish". Reproducible by
starting and stopping mirroring in quick succession — it hit on the 3rd
attempt of a session where each stop came ~1.6s after the start.

## Why earlier investigations went wrong

Two conclusions from earlier sessions were withdrawn once real evidence
was collected:

- "The TEARDOWN request never leaves a trace in the log, so it never
  arrived." `raop_handler_teardown()` logs at `LOGGER_DEBUG`
  (`lib/raop_handlers.h`), and the service runs without `-d` — absence of
  that line proves nothing. Its *effect* does log at INFO
  (`release_display: hid video, epoch N`, via `RESET_TYPE_RTP_SHUTDOWN`).
- "`httpd_thread()`'s serial loop is head-of-line-blocking the TEARDOWN."
  Disproved: during the captured failure the server answered every
  request within 0.5ms. The peek-stall defect found while chasing this is
  real and was fixed (see
  `2026-09-21-httpd-peek-stall-and-on-url-overread.md`), but it is not
  this symptom's cause.

## Evidence (2026-09-22, real client, real hardware)

A persistent capture of the RTSP control port plus a timestamped mirror
of `/var/log/uxplay.log` was armed on the Pi before the repro, so the
failing attempt was recorded in full rather than reasoned about:

| session | client port | handshake | stop |
|---|---|---|---|
| A | 59995 | 45.89 → SETUP 46.07 | TEARDOWN 47.65 → 200 OK, FIN |
| B | 60003 | 49.56 → SETUP 49.97 | TEARDOWN 51.20 → 200 OK, FIN |
| C | 60009 | 52.83 → SETUP 52.94 | no TEARDOWN ever sent |

In the failing session C the Mac kept sending `POST /feedback` every 2s
(answered `200 OK` in 0.4ms each) and kept streaming real video on the
mirror TCP socket (11.8MB and climbing, `Recv-Q` 0 — the server consumed
all of it). The user confirmed at that moment: TV showing live video,
Mac's Control Center showing mirroring **off**.

Server-side, across the whole episode: zero non-200 responses, zero RSTs,
zero refused or extra connection attempts, `Recv-Q` never above 0. The
only retransmissions were of the server's own responses (ordinary WiFi
loss, `retrans:0/2`).

Re-enabling mirroring in Control Center produced **no new protocol
traffic at all** — no new TCP connection, no SETUP/RECORD, just the same
`/feedback` stream continuing. macOS re-adopted the session that had
never stopped, and its UI became consistent again.

## Conclusion

macOS's AirPlay stack and its own mirroring UI diverge: the stop click
tears down the UI state without sending TEARDOWN, leaving a fully live,
actively streaming session. The receiver cannot detect this — the stream
and heartbeats are indistinguishable from real mirroring, so no
server-side heuristic and no timeout can help. `-reset N` specifically
cannot: client feedback keeps arriving on time, so the missed-feedback
counter never advances.

## Workaround (confirmed working)

Re-select the receiver in Control Center — macOS re-binds its UI to the
live session — then stop mirroring again.

## If this needs a real mitigation later

The only receiver-side defence is an explicit "drop the current client"
control that does not depend on the Mac's state (a TV-remote HDMI-CEC key
on `/dev/cec0`, or a command channel alongside the existing `-ofifo`).
Deliberately not built: the workaround is trivial and this is a client
bug.

## Diagnostics left armed on the Pi

`rtsp-capture.service` (`/usr/local/bin/rtsp-capture-arm` — re-reads
uxplay's RTSP port on every start, since it is chosen at startup;
rotates 3x20MB): `enabled`, diagnostic-only, not part of the image build.

`/var/log/uxplay.log` carries UTC millisecond timestamps in the same format
this investigation used: `uxplay.service` runs uxplay under
`/usr/local/bin/log-ts` (see README's on-device diagnostics section).
