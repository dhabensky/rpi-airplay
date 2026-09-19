# `test_ntp_resync.py`

**Location:** `tools/pytest/test_ntp_resync.py`
**Stack:** e2e, Docker-only (no Pi) — `two_process_runner` fixture starts an
unmodified `uxplay_debug` and `tools/synthetic-client.cpp`'s `ntpresync` mode
as two separate processes in one container.
**Input:** no fixture files — `synthetic-client` builds its RTSP/RTP traffic
in-process from a real, captured AAC-ELD frame baked into its own source.

## Revisions tested

- **Before:** UxPlay `dhabensky-clean-2` commit `eb229e1` ("Add -threadtest
  diagnostic instrumentation to the audio renderer") — has the
  `RENDER-BUFFER-CALL` diagnostic the test parses, but not yet the fix.
- **After:** UxPlay `dhabensky-clean-2` commit `daa9477` ("Fix audio dying
  permanently after a repeated audio SETUP on a connection") — the very next
  commit, containing only the isolated behavioral fix
  (`lib/raop_rtp.c`'s `raop_rtp_start_audio()` reset + a companion
  `audio_renderer.c` base-time refresh on same-codec restart).

Note on why "before" isn't the fix's direct git parent: the diagnostic
instrumentation is deliberately its own commit, landing immediately before
the fix, precisely so this before/after boundary exists at all — with no
diagnostic markers at the fix's own git parent, "run the suite against the
parent" would produce a `driver did not complete` failure for the wrong
reason (no `RENDER-BUFFER-CALL` output whatsoever, fix or no fix), not
evidence of the actual bug.

Reproduce: `tools/pytest/.venv/bin/pytest tools/pytest/test_ntp_resync.py
--uxplay-ref eb229e1` (expect FAIL) vs `--uxplay-ref daa9477` (expect PASS).

## Before (`eb229e1`) — FAIL

```
AssertionError: probe A rendered at t=173906.9631 BEFORE the second sync
(t=173907.3667) -- stale sync state wasn't reset on restart
```

![ntp-resync before](img/ntp_resync_before.png)

**Interpretation:** the picture is the whole story in one glance. The
`render` track's `RENDER-BUFFER-CALL seqnum=1` marker sits at t=0.0 (the
very first event in the trace), a full ~0.40s *before* the `sync` track's
`SENT-SYNC-2` marker (matching the assertion above exactly: probe A at
173906.9631, `SENT-SYNC-2` at 173907.3667). Probe A (`seqnum=1`) was sent
deliberately *before* any fresh sync packet, specifically to land in the
exact window the bug lives in — and it rendered immediately anyway, using
the stale RTP-timestamp-to-NTP mapping left over from the *first* sync
(sent before the TEARDOWN+SETUP restart on this connection). `seqnum=2`
(probe B, sent *after* the fresh sync) renders correctly, ~0.2s after
`SENT-SYNC-2` — so this isn't "nothing ever renders," it's specifically the
restart's cold-start guard failing to actually reset, exactly as
documented.

## After (`daa9477`) — PASS

![ntp-resync after](img/ntp_resync_after.png)

**Interpretation:** `SENT-SYNC-2` now sits at t=0.0 (it's the earliest event
in this trace — probe A's render no longer preempts it), and *both*
`RENDER-BUFFER-CALL` markers land together at t≈0.204s, ~80 microseconds
apart (indistinguishable at this plot's scale, which is itself informative:
the raw JSON confirms two nearly back-to-back renders, not a hang). Reading
the raw trace directly: `seqnum=1` and `seqnum=2` both render ~0.204s
*after* `SENT-SYNC-2`, and their `ntp_time` values differ by 2,267,648ns --
within 75ns of the theoretically exact 100-RTP-tick delta at 44100Hz
(2,267,573ns), confirming the test's own "sane" check with real numbers.
Probe A was genuinely withheld until the fresh sync arrived, then released
promptly along with probe B, matching the fix's documented intent exactly.

## Verdict

Real bug, real fix, real before/after boundary — no caveats. Confirms the
fix's core claim (stale sync state reset on restart) with a picture that
needs no supporting narrative to read correctly.
