# Bug: audio dies permanently after a burst of repeated SETUP requests (YouTube track-switching)

Status: **confirmed reproducible, long-standing, root cause not yet
pinned down — diagnostic capture needed before a fix can be planned**

## 1. Description (as reported and directly reproduced)

Reported: 2026-09-13, on the freshly reflashed, regression-tested,
reverted baseline (see `bugs/2026-09-13-audio-resume-latency-after-
teardown.md` for that revert).

- Trigger: switching tracks on YouTube (in a browser tab) while
  AirPlay-mirroring that tab. Not tied to a specific number of switches —
  reproduced with a burst of 4 and separately a burst of 7 rapid `SETUP`
  requests.
- **Confirmed long-standing, not a regression**: the user has seen this
  before tonight's session, on older builds.
- Symptom: audio goes completely and permanently silent. **Video is
  unaffected** — confirmed via `tools/drmdump.c` polling plane 98's
  `fb_id` during a live reproduction: it kept changing (677 -> 675 -> 673
  across three 2s-spaced polls), i.e. genuinely still rendering new
  frames, while audio stayed dead.
- Does **not** self-recover. Confirmed twice: after the SETUP burst stops
  appearing in the log, audio remains silent indefinitely (checked
  immediately after and again ~30s later in one reproduction).

## 2. Reproduced cleanly, independent of tonight's other work

This was directly reproduced **twice** against the fully-reverted
baseline (submodule `d2731a6`, content-identical to `7402efa` --
confirmed via empty diff, see the audio-resume-latency bug doc) running
as the **normal, unmodified production `uxplay.service`** (no `-d`, no
manual restart, no debug flags) -- ruling out any involvement from
tonight's frozen-frame-hide feature or its revert. This is not something
to bisect against a recent commit; it predates every change made this
session.

(An earlier reproduction attempt tonight was contaminated by the
investigator manually restarting the service mid-session to enable debug
logging, which the user correctly flagged as not representative -- that
attempt is discarded from evidence; both reproductions counted above are
against the clean, untouched production service.)

## 3. What's confirmed vs. still unknown

**Confirmed** (from the plain `LOGGER_INFO`-level production log, both
reproductions):
```
ct=8 spf=480 usingScreen=1 isMedia=1  audioFormat=0x1000000
raop_rtp starting audio
raop_rtp local control port socket 46 port UDP <fresh port>
raop_rtp local data port    socket 48 port UDP <fresh port>
AUDIO SETUP response: dataPort=<fresh> controlPort=<fresh> remote_cport=<fresh> ct=8 sr=44100
```
repeating 4-7 times in quick succession, **each with a brand new port
pair**, then nothing further logged. The ALSA PCM device
(`/dev/snd/pcmC0D0p`) stays held open by the main process throughout
(`fuser` confirmed this during the first reproduction).

**Traced in the source** (`lib/raop_rtp.c`), not yet confirmed against
which branch actually executes live:
- `raop_rtp_start_audio()` (`raop_rtp.c:655` on) has a redundant-SETUP
  guard: `if (raop_rtp->running || !raop_rtp->joined) { ...return cached
  ports... }` (`raop_rtp.c:664`). A **fresh port every time**, as
  observed, means this guard is *not* firing on any of these calls --
  each one is taking the real thread-creation path.
- The only two places that touch `raop_rtp->joined`: initialized to `1`
  in `raop_rtp_new()` (`raop_rtp.c:177`); set back to `1` only inside
  `raop_rtp_stop()` (`raop_rtp.c:847`), which itself refuses to run at all
  if `!raop_rtp->running` (`raop_rtp.c:823`) -- i.e. **a thread that has
  already exited on its own is never joined or marked joined by anything
  in this file.** Whether that's what's actually happening here (vs. a
  real `TEARDOWN(96)` arriving before each SETUP and legitimately calling
  `raop_rtp_stop()` while the thread is still alive, which would also
  explain a fresh port each time without being a bug) is **not yet
  determined** -- both would produce the exact same fresh-port-every-time
  log signature at `LOGGER_INFO` level; distinguishing them needs
  `-d`/`LOGGER_DEBUG` output (which logs `"TEARDOWN request, 96=.., 110=.."`,
  `raop_rtp.c` / `raop_handlers.h`) captured against a *clean*
  reproduction -- the one debug capture attempted tonight was against a
  freshly-restarted process and is not trustworthy for this (see section
  2's caveat).
- Elevated thread count observed on the process during the first live
  reproduction (14 threads for a process that should have on the order of
  5-8) -- noted as a possible lead (thread accumulation if threads really
  are going unjoined) but **not yet confirmed** as related rather than
  coincidental; not re-checked on the second, cleaner reproduction.
- This general area (`raop_rtp_start_audio()`'s redundant-SETUP handling)
  is already flagged as a known risk in
  `docs/video-audio-threading-and-state-machine.md` section 5, item 2 --
  written before this specific bug was reproduced live, from reading the
  code alone.

**Not yet known**: whether real audio RTP *data* packets ever arrive at
the last-opened port at all (client-side silently giving up vs.
server-side silently failing to process what does arrive), whether the
thread count genuinely grows unboundedly across repeated occurrences, and
whether a real `TEARDOWN(96)` request precedes each of these SETUPs.

## 4. Next diagnostic step (not yet done)

A clean `-d`/full-debug capture is needed, taken **without restarting the
service mid-reproduction** this time (that's what made the first attempt
tonight non-representative) -- e.g. enable debug logging in the
`uxplay.service` unit itself (or accept losing the very first few seconds
of an already-fresh session) rather than stopping and manually restarting
a session the user is actively using. This should distinguish the two
live hypotheses above (thread never joined vs. legitimate repeated
teardown+setup) before any fix is designed.

## Fixed in

*(not yet fixed -- root cause not yet pinned down; fill in once the
diagnostic step above narrows it down and a fix is applied)*
