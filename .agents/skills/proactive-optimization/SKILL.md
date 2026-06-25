---
name: proactive-optimization
description: At a task boundary, surface optimisation candidates -- workflow ergonomics, cross-repo inconsistency, doc drift, repeated manual steps. Use when the `remind_proactive_optimization.sh` Stop hook nudges, or just before declaring a task done.
---

# proactive-optimization

CLAUDE.md says "if you spot a workflow that's clunky, an inconsistency, a step that could be a script -- raise it, don't silently push through." This skill is the auto-invocation surface for that rule. The paired `remind_proactive_optimization.sh` Stop hook fires at task boundaries; this skill is the rubric for deciding what (if anything) is worth saying.

## When to use

- A PR just merged and you're about to close out the turn.
- A multi-step task finished and you're about to report.
- The `remind_proactive_optimization.sh` Stop hook surfaced its reminder.
- You're approving a workflow you already noticed could be tighter -- raise it now rather than next time.

## Candidate categories

| Category | Signal you saw it | What to propose |
|---|---|---|
| **Workflow ergonomics** | You ran the same multi-step ritual twice this session; you typed a 5-line bash pipeline that another session will retype; a slash command exists but is missing one obvious step | A new `.claude/commands/<name>.md`, a step added to an existing command, a skill, or a permanent `.claude/scripts/<name>.sh` |
| **Cross-repo inconsistency** | You patched repo A in a way repo B should also receive; a base subtree upgrade landed in only some downstreams; a hook lives in `docker_harness` that downstream repos would benefit from | A batch script, a follow-up issue, or a `/batch-base-upgrade`-style fanout |
| **Doc drift** | TEST.md / CHANGELOG / a 4-language README disagrees with reality; a CLAUDE.md table mentions a path that no longer exists; an instinct in `instincts.yaml` mismatches the narrative | A doc-only PR or a one-line patch |
| **Manual repetition** | You ran a `gh issue close` loop, a `git -C <repo> ...` loop, a parser-fallback prone command sequence three or more times | A permanent script in `.claude/scripts/<name>.sh` (the existing fix for parser-fallback fatigue) |

If none of the four categories fit, **do not invent a candidate**. The whole rule's value is that it's a real signal -- noise here erodes the user's trust in the reminder.

## How to phrase the offer

One short paragraph, framed as a question the user can redirect. Examples:

- **Good:** "Spotted that I ran the `gh issue close` + `gh comment` two-step three times this session -- propose `.claude/scripts/close-issue-with-comment.sh` as a follow-up. Worth it, or noise?"
- **Good:** "TEST.md table currently lists 31 hooks; filesystem has 32. Minor drift -- want a one-line patch in the next PR, or defer to next batch?"
- **Bad (unilateral):** "I added a script for the issue-close loop." (You did not ask -- you decided.)
- **Bad (vague):** "I noticed some things could be improved." (No artifact, no scope -- user can't engage.)

## When NOT to offer

- Mid-implementation of a feature -- finish first, then raise after.
- Debugging a specific failure -- the candidate distracts from the root cause.
- You only saw the pattern once. Three repetitions or a clear cross-repo gap, not a one-off.
- You already raised it earlier in the session and the user did not engage -- the throttle marker (TMPDIR) should already suppress this.

## Hook integration

`.claude/hooks/remind_proactive_optimization.sh` (Stop hook) emits a one-shot reminder per session when:

- A "task boundary" signal fired (a `gh pr merge` Bash call landed this session, OR tool-call count >= `PROACTIVE_OPTIMIZATION_REMIND_THRESHOLD`, default 50), AND
- The session did NOT already mention any of the four candidate categories (matched against a regex covering "optimisation / automate / scripted / DRY / redundant / skill candidate / skill-ify" etc.).

Non-blocking. The hook cannot raise the candidate itself -- only the agent (you) can. Disable per-session with `PROACTIVE_OPTIMIZATION_REMIND_DISABLE=1`.

## Anti-patterns

- **Listing candidates at the end of every task by reflex.** The point is to surface real ones; the reminder fires when both heuristics hold (task boundary + no prior mention), not on every Stop.
- **Listing candidates inside a feature implementation.** Finish the task first. The hook is a Stop-hook for a reason.
- **Treating the reminder as a command.** It's a one-shot nudge. If nothing fits the four categories, say so briefly or stay silent.
- **Offering candidates without an artifact in mind.** "We could do X better" with no script / file / follow-up sketch is not actionable; the user can't redirect what does not exist.
