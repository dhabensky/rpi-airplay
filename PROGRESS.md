# RPi3B+ AirPlay Receiver — Progress Summary (current period)

Narrative log, newest period only. Earlier entries were not summarised or
dropped — they are verbatim, one file per period, under `docs/archive/`:

- [`PROGRESS-2026-09-06--2026-09-12.md`](docs/archive/PROGRESS-2026-09-06--2026-09-12.md)
  — project baseline, A/V sync and seeks, the `-capture`/`-replay` harness,
  configurable overscan, boot-console bleed-through, frozen last frame.
- [`PROGRESS-2026-09-13--2026-09-19.md`](docs/archive/PROGRESS-2026-09-13--2026-09-19.md)
  — the audio-dies and audio-dropout bugs, repo/apt cleanup, the pytest
  suite, the `dhabensky-clean-2` history rewrites and their review rounds.

Everything in those files is history; `README.md` and `docs/` describe the
current state.

## 2026-09-20/21: idle menu delivered end to end, plus two real httpd defects

The idle menu screen (device name / IP / SSID on the primary plane) is
now actually delivered, not just rendered. Four things landed, each
verified on real hardware rather than reasoned about:

- Menu repaint on disconnect within ~2s instead of up to 5 minutes
  (`uxplay-menu-render-watch` tails UxPlay's existing log output for
  `release_display: hid video` / `lost connection with client` --
  nothing in UxPlay was touched, per this feature's standing boundary).
- Repaint suppressed while a client holds an ESTAB session, so the
  5-minute timer can no longer bleed menu text into a pillarboxed
  session's margins mid-stream.
- `choose_codec()` blanks the primary plane unconditionally (submodule
  `3e499e9`), with a real negative control: the pre-fix binary
  reproduces stale menu content bleeding into an active pillarboxed
  session on a fast reconnect, the post-fix one doesn't.
- §4's frozen-last-frame-after-TEARDOWN fix, the attempt that failed
  twice before, now works via `video_renderer_release_display()` --
  deferred onto the main loop and epoch-guarded, never called inline
  (submodule `e17c6b3`). 10 real SETUP->stream->TEARDOWN->reconnect
  cycles through `synthetic-client mirrortest`, not `-replay`.
- §6's "100% CPU while idle" is gone: it was `uxplay_debug` spinning on
  the overscan FIFO (submodule `b48986e`). Idle load average is now 0.01.

Chasing a separate "mirroring sometimes doesn't stop" report produced two
real, independent, latent defects in the HTTP layer -- neither of which
turned out to be that symptom's cause (see the 2026-09-22 entry). Both
are fixed and documented in
`docs/bugs/2026-09-21-httpd-peek-stall-and-on-url-overread.md`:
`httpd_thread()`'s captive 8-byte reverse-HTTP peek could block the
single serial loop forever on a silent client, wedging every other
connection; and upstream's own `on_url()` read 8 bytes past the buffer
llhttp was fed. Five developer rounds and four independent reviews, of
which rounds 1-4 each only moved the conditions under which the
over-read was reachable -- round 5 removed it, confirmed by ASan/UBSan
(deterministic heap-buffer-overflow before, 56/56 clean after) and 75
runs on the Pi. New coverage: `tests/test_on_url_protocol_bounds.c`, four
`synthetic-client` modes (`peekstall`, `shorturl`, `shorturlfrag`,
`shorturlsweep`), four Docker-only pytest modules.

## 2026-09-22: "mirroring doesn't stop" is a macOS bug, proved on the wire

The long-running complaint is closed as **not ours**, with wire evidence
instead of inference: `docs/bugs/2026-09-22-stop-mirroring-not-honored-client-side.md`.

A persistent RTSP capture plus a timestamped log mirror were armed on the
Pi *before* asking for a repro (`rtsp-capture.service`,
`uxplay-ts.service`, both diagnostic-only, not in the image build), so
the failing attempt was recorded completely. Of three rapid
start/stop cycles, the first two sent a proper TEARDOWN pair and were
answered in 0.5-5ms; the third sent none at all, while the Mac kept
heartbeating every 2s and kept streaming real video (11.8MB and
climbing, `Recv-Q` 0). At that moment the user confirmed the TV showed
live video and the Mac's Control Center showed mirroring **off**.
Re-enabling mirroring produced zero new protocol traffic -- macOS simply
re-adopted the session that had never stopped.

So macOS's AirPlay stack and its own UI diverge, and the receiver cannot
tell: the stream and heartbeats are indistinguishable from real
mirroring, which also means `-reset N` can never fire. Two earlier
working hypotheses died here: "no TEARDOWN line in the log, so it never
arrived" (that line is `LOGGER_DEBUG`, and the service runs without
`-d`), and "the httpd peek stall is delaying the TEARDOWN" (the server
answered every request within 0.5ms during the failure). Workaround,
confirmed: re-select the receiver, then stop again. A receiver-side kill
switch (HDMI-CEC key, or a command channel next to `-ofifo`) was
deliberately not built.

## 2026-09-23: direct-Ethernet backup management channel

`eth0-backup-ip.service` keeps `169.254.100.1/16 scope link` on eth0 (DietPi
never ifup's eth0 when WiFi is enabled, so eth0 was simply down before). Three
developer/reviewer rounds; `make test-eth-backup` 23/23 under nspawn. The
round-1 review caught that `hostname -I` in `uxplay-menu-render` would have put
the backup address on the TV menu; the menu now shows the first global IPv4.

Deployed live over WiFi (checksums match the repo) and checked with a real
cable to the Mac: the Pi got carrier and holds the address, the menu IP stays
the WiFi address, mDNS answers on both interfaces. Real-hardware finding: with
the Mac's WiFi up, macOS routes 169.254/16 via `en0`, so a plain
`ssh root@169.254.100.1` times out; `ssh -o BindInterface=en9 ...` and
`ssh root@fe80::ba27:ebff:feef:9450%en9` both work. README documents this.

## 2026-09-25: the round itself got cheaper, and a day's worth of friction removed

The day started on the menu/unit consolidation and turned into an audit of
why rounds were slow. Measured across one feature's 16 agent runs: 1220
shell commands, 294 minutes of tool time, **112 of them `sleep`**, and 156
separate ssh invocations each paying connection setup. Most of that was
missing recipes rather than carelessness — every agent improvised the same
workarounds and paid for them.

Delivered, in dependency order:

- **`-efifo`, a machine-readable session-event channel** (submodule
  `08abb3c`), replacing the idle menu's habit of grepping
  `/var/log/uxplay.log` for `release_display: hid video`. The user's
  objection was the right one: log text is a developer artifact, not a
  contract. Emission is serialized with the state test under one mutex —
  an earlier revision committed the state and wrote outside it, which let
  two threads invert a `begin`/`end` pair on the wire (measured: 31
  inversions per 80640 lines).
- **One supervised daemon instead of seven units.** `uxplay-menu.service`
  (`Type=notify`, `WatchdogSec=30s`) consumes those events, watches
  `/etc/default/uxplay`, pushes overscan and runs the periodic refresh;
  `uxplay-menu-render{,-watch}`, the timer, both `.path` units and
  `uxplay-overscan-sync` are gone. Idle cost: 0 CPU ticks over 60 s
  against a resident 4-process shell pipeline before.
- **`tools/pissh`** — one multiplexed entry point: 0.53-1.14 s per plain
  ssh against 0.02-0.03 s reused, a per-call timeout (a dead link used to
  hang indefinitely, and a poisoned master hung *every* later call for ten
  minutes), and a disposable per-repo `known_hosts` so a reflash is
  recoverable with `pissh -k` instead of hand-editing `~/.ssh`.
- **`make deploy`** with per-artifact targets, replacing `tools/deploy.sh`,
  which duplicated the build recipe and deployed one of the six binaries
  the device runs — the reason every agent hand-rolled `scp` all day.
  Verified on hardware after the cable came back: skip-if-identical for
  all six in 0.5 s, and a deliberately corrupted device copy detected,
  replaced and its unit restarted.
- **`make pytest`** that bootstraps its own venv, and **env-overridable
  intervals** in the daemon: proving the periodic refresh fires went from
  300 s to 6 s.
- **A reproducibility check that can fail.**
  `tools/verify-reproducible-build.sh` built into `mktemp -d`, which Docker
  here does not share, so the build exited 0 with a 0-byte artifact and the
  script compared two empty files and printed PASS. Every reproducibility
  claim made through it on this machine was meaningless. Artifacts are now
  truncated before a build and deleted when the check fails — a stale file
  at the output path used to pass the non-empty test, and `conftest.py`
  would then hand that placeholder to the suite as the binary under test.
- **One source of truth for provisioned files.** `customize-root.sh`'s
  heredoc for `/etc/default/uxplay` overwrote the checked-in copy whenever
  `personal.env` supplied a key; measured on the pre-change code, a comment
  added to the repo's file reached the image **zero** times. Values are now
  substituted into the checked-in file through marked lines.
- **`PROGRESS.md` 2161 → 98 lines and `REBUILD-STATUS.md` 1289 → 120**,
  with earlier entries verbatim under `docs/archive/` (byte-identity
  proven by sha256 of the concatenation), and the pipeline docs corrected
  against the submodule with every claim naming a symbol that exists — 186
  checked mechanically, so staleness is now greppable instead of
  discovered mid-round.

The most expensive single defect was not a bug in the product: `UxPlay/.git`
sat in `build/uxplay_debug`'s prerequisites, so **any** git command advanced
its mtime and sent the artifact into a multi-minute container rebuild. Every
agent in every round paid it.

Two claims were withdrawn after being checked rather than defended: that a
non-UTF-8 display name can stop `uxplay.service` (systemd ignores the value
and the unit starts), and that worktree checkouts were multiplying grep's
search space (the four hits were four different real files). A guard that
had been demanded for the event FIFO was also removed after a reviewer
measured that it *created* the failure it was meant to prevent — reopening
the path walked the consumer off the inode uxplay still writes to.
