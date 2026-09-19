# `test_video_reconnect.py`

**Location:** `tools/pytest/test_video_reconnect.py`
**Stack:** e2e, **real Pi hardware** (`pi_uxplay_deployed` — v4l2h264dec HW
decode, real DRM/kmssink). Generates a synthetic H.264 test pattern via
`ffmpeg` + `tools/make-synthetic-cap.py`, deploys, replays with
`UX_RECONNECT_MODE=real` (the actual production `video_reset()` +
`skip_video_rebuild` reconnect path) and a simulated reconnect partway
through.
**Input:** synthetic, generated fresh each run (no committed fixture).

## Revisions tested

- **Attempted before:** UxPlay `dhabensky-clean-2` commit `c5a19be` ("Fix
  stale audio continuing to play through a seek") — the direct git parent
  of `aaad0bb` below, i.e. the commit right before `skip_video_rebuild` is
  introduced.
- **After:** UxPlay `dhabensky-clean-2` commit `01cc470` ("Add a
  capture/replay test harness for reconnect and A/V-sync testing") — the
  earliest commit at which `-replay` (this test's own mechanism) exists at
  all; `skip_video_rebuild` (introduced two commits earlier, at `aaad0bb`)
  is already active here.

Reproduce: `tools/pytest/.venv/bin/pytest tools/pytest/test_video_reconnect.py
--uxplay-ref c5a19be` (structurally can't run at all) vs
`--uxplay-ref 01cc470` (expect PASS).

## Attempted before (`c5a19be`) — cannot run at all

```
AssertionError: 'RECONNECT DONE' never appeared -- reconnect simulation
didn't fire
```

**Interpretation, and why this genuinely surprised me:** I expected this to
FAIL on a stalled render count, the normal shape of this bug. Instead the
reconnect simulation never even started. Investigated rather than assumed
the test was broken: `-replay` and everything `UX_RECONNECT_MODE` depends
on is introduced by `01cc470`, a *later* commit than `aaad0bb` (the
`skip_video_rebuild` fix this test targets) -- on this branch's clean,
non-repeating history, the capture/replay harness was only built once, for
a *different* purpose (A/V-sync testing), well after the reconnect bug it
would otherwise be perfect for reproducing was already fixed directly.
There is no commit on `dhabensky-clean-2` where `-replay` exists and
`skip_video_rebuild` doesn't: by construction, this branch never has a
window where the fix is absent AND the tooling to demonstrate its absence
is present. No before-picture exists because no before-run produced any
data at all.

## After (`01cc470`) — PASS

![video-reconnect after](img/video_reconnect_after.png)

**Interpretation:** `skip_video_rebuild=1` (confirmed directly in
`build/logs/video-reconnect.log`: `RECONNECT DONE (skip_video_rebuild=1)`),
and the picture shows why that matters: the render count climbs
continuously and near-linearly from t=0 through past `RECONNECT DONE`
(the dashed line at t≈124s) to the end of the run at t≈252s, with no
plateau or discontinuity anywhere near the reconnect -- 245 renders by the
end, comfortably above `MIN_RENDERS_AFTER=10`. This is real, positive
confirmation that the current, correct behavior works end-to-end on real
hardware; it just isn't a fail→pass pair.

## Verdict

**Not proof of this specific fix, for a different and more fundamental
reason than initially expected.** This isn't a case of picking the wrong
commit pair (as an earlier attempt on a differently-structured branch
found) -- on `dhabensky-clean-2` specifically, no valid "before" commit
can exist at all: the test's own mechanism (`-replay`) was built later
than the fix it would otherwise verify, and this branch's history was
deliberately constructed to never contain a commit where a bug exists in
a form later tooling could reveal. The only way to get real before/after
evidence for this bug on this branch would be building a *different*
reconnect-triggering mechanism that exists from `df67c212a4` onward (e.g.
one using the real RTSP/RTP layer directly, not `-replay`) -- new work,
not attempted here, flagged as follow-up rather than forced into a report
that doesn't fit. The test itself remains legitimate regression coverage
(a real reconnect on real hardware exercising the real production path,
confirmed passing above) and is not a deletion candidate; only the
before/after claim for this specific bug is withdrawn.
