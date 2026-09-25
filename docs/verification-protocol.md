# Verification protocol

What "verified" means in this project, for both roles of the
developer→reviewer loop (`CLAUDE.md`). Agent definitions
(`.claude/agents/*.md`) reference this file instead of restating it, and a
round's brief should only have to name the task — not re-derive the rules.

Every item here exists because it was violated once and cost real time.

## Evidence classes

- **`-replay` is never acceptance evidence** for anything touching the
  video/audio pipeline, DRM planes, or the httpd/RAOP threads. Its
  single-threaded feeder cannot exercise the interleaving that has caused
  four reverted regressions here. Acceptance requires real RTSP traffic
  (`UxPlay/tools/synthetic-client.cpp`'s `mirrortest`) **and** a real run
  on the Pi. `-replay` is fine for fast iteration during development.
- **A protective mechanism must be exercised against the real
  counterpart**, not a stub. A stub takes whatever semantics make the test
  pass: a FIFO-revalidation guard passed its container control and, against
  the real writer that holds its fd for the process lifetime, turned a
  working consumer into a silently deaf one.
- **Claims about impossibility need the same evidence as claims about
  behaviour.** "X cannot happen because the structure forbids it" is an
  assertion about code; four consecutive rounds shipped a false one.

## Discrimination

- A regression test proves nothing until it has been **shown failing on
  the unfixed code**. Include that run.
- Distinguish **removing a defect** from **removing the path that reaches
  it**. A caller-side bound over a function that still over-reads is a
  mitigation; say so.
- When a task starts from a user-visible symptom, report separately: the
  defect found, and whether the *symptom* was reproduced before the change
  and confirmed gone after. A real defect found nearby is not evidence of
  cause.

## Reporting

- Label every claim **measured**, **inferred**, or **unverified**. Never
  present reasoning as measurement; an honest "could not verify" is a
  complete answer.
- Cite `file:line` for each change and real command output for each check.
- Recompute counts (files, tests, cases) immediately before writing them.

## The device

`rpi-airplay.local` (currently `169.254.100.1` over the direct Ethernet
link; see `README.md` for that channel). Password `dietpi`; SSH needs
`-o PreferredAuthentications=password -o PubkeyAuthentication=no`.
**Deploying, restarting services and running tests there is
pre-authorized** — the card is reflashable and holds nothing precious, so
never stall a round to hand a copy-paste command back. **Flashing the SD
card is not** — that stays manual and user-driven.

Always record the deployed binary's `sha256`, and restore anything you
changed (config values, `printk`, test fixtures, scratch files), saying so
explicitly.

### Conditions that are expected, not defects

- The board reports under-voltage and has throttled (`vcgencmd
  get_throttled` non-zero). Real hardware condition of the current
  location.
- WiFi may be down, so the idle menu renders "(no IP yet)" and no network
  time source is reachable. The device has no RTC: its clock can be days
  off until someone pushes the time from the host.
- `console=tty1` is deliberate (the boot log must render), so kernel
  messages repaint `/dev/fb0` — which is DRM plane 86. **Any plane-hash
  measurement must quiet `printk` first** (`1 4 1 7`) and restore it
  (`4 4 1 7`) afterwards, or the hashes are noise.

## Cost discipline

Measured across one feature's 16 agent runs: 1220 shell commands, 294
minutes of tool time, of which **112 minutes was `sleep`**. Budget matters
as much as rigour.

- **Never wait on a fixed `sleep` for something observable.** Poll the
  actual condition on a short interval with a hard cap.
- **Long production intervals must be overridable from the environment**
  (refresh periods, retry budgets, watchdogs) with the production value as
  the default. Waiting five minutes to prove a five-minute timer fires is
  not verification, it is padding.
- **Batch device work into one script** and run it detached; the wired link
  flaps, and 156 single-command round-trips paid connection setup 156
  times. Reach the device through `tools/pissh` (run a command, `-s` a script
  on stdin, `-p`/`-g` to copy a file) so the multiplexed master is reused and
  the address stays in one place.
- **Do not run `make image` to inspect a unit file or a script** — read the
  extracted rootfs. Build the image once, at the end, when the artifact
  itself is the claim.
- Scope local searches to a directory; repo-wide greps averaged seven
  seconds each.
