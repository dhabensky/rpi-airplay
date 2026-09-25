# rpi-airplay — working agreement

## Developer/reviewer loop for implementation tasks

For any nontrivial code change (new feature, real bug fix, history
rewrite) — not a one-line typo fix — don't implement directly in the main
session. Once the task or plan is agreed with the user:

1. Delegate implementation to the `developer` subagent
   (`.claude/agents/developer.md`), with the full task/plan in the
   prompt — it starts with zero context, so include everything it needs:
   what to do, why, and any relevant background already established in
   conversation.
2. Send the developer's result (diff + its own report) to the `reviewer`
   subagent (`.claude/agents/reviewer.md`): give it the diff, the
   original task/plan, and the developer's report, and ask for a
   findings list.
3. If the reviewer's verdict is **NEEDS ANOTHER ROUND**: send its
   findings back to a fresh `developer` call for another pass (include
   the findings verbatim plus enough of the original task for context).
   If **APPROVE**: done — report the result to the user yourself.
4. **Cap at 3 developer→reviewer round-trips.** If still not clean after
   3 rounds, stop looping and report the remaining findings to the user
   directly instead of continuing — that's a signal the task or plan
   needs rethinking, not more automated iteration.

Each round is a fresh subagent call (not a `fork`) — developer and
reviewer must not share hidden context; the reviewer's value is catching
what the developer missed working only from the diff and the original
task, the way an independent human reviewer would.

## What counts as trivial enough to skip the loop

Direct edits, no loop, are allowed for exactly two things: documentation
(`docs/`, `README.md`, `PROGRESS.md`, bug write-ups) and a single-line
configuration value.

Everything that ships to the device goes through the loop — anything
under `UxPlay/`, `image-builder/files/`, `tools/` — **including comment
trims and one-line code fixes**. "It's only a comment" and "it's a
two-line fix" have both been used here to bypass review; one of them was
committed self-written and self-reviewed, and had to be rolled back on
the user's instruction. The cap stays at 3 developer→reviewer
round-trips: at that point stop and report to the user, and only the user
extends it.

## Diagnosing a user-visible problem

1. **Never restate the user's observation in words they didn't use.**
   Quote them, or measure it. Characterising a symptom from inference
   once produced a description that matched nothing that actually
   happened, and the user had to say so.
2. **Get ground truth before hypothesising.** For anything user-visible,
   arm a persistent capture first (packet capture, timestamped logs,
   `-capture`), then ask for a single reproduction. One instrumented
   repro beats several blind hypotheses — and never make the user
   re-trigger a live session once per hypothesis.
3. **Rule out the environment before the code**: network, cabling and RF
   interference, stale service state. A reported video regression here
   turned out to be pickup from a coiled cable lying near the device.
4. **Take the user's environment statements literally.** When they say
   the Pi is on USB, work the USB path; don't substitute an inferred one
   and keep scanning the network.
5. **Absence of a log line proves nothing until you check its log
   level.** A missing `TEARDOWN` line sustained a wrong hypothesis for
   days; that line only exists at `LOGGER_DEBUG`, and the service runs
   without `-d`.
6. **A protective mechanism is only as good as the counterpart it was
   tested against.** When asking for a guard against a cross-process
   failure — a dead reader, a replaced file, a wedged supervisor — demand
   evidence from the real processes, not a stub. A stub takes whatever
   semantics make the test pass. A FIFO-revalidation guard demanded here
   passed its container control and, against the real writer that holds
   its fd for the process lifetime, turned a working consumer into a
   silently deaf one — a guard that made the failure it targeted
   reachable for the first time.
