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

Skip this loop for trivial changes (a typo, a one-line config tweak) —
use judgment, don't force ceremony onto small edits.
