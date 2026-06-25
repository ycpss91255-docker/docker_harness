---
name: strategic-compact
description: Decide when to manually run /compact at task boundaries instead of letting Claude Code's auto-compaction fire mid-task. Use this skill when you see the `remind_strategic_compact.sh` hook nudge, or whenever you're considering whether to compact.
---

# strategic-compact

Claude Code auto-compacts when context approaches the model limit. That works, but the fire-point is often mid-task -- losing variable names, partial state, and reasoning you wanted to keep. **Strategic compact** is the inverse: compact at *task boundaries* (PR merged, plan distilled, todo list cleared) so what survives is the part you wanted to keep.

The paired `remind_strategic_compact.sh` Stop hook surfaces a proposal when boundary signals show up; this skill is the rubric for whether to act on it.

## When to `/compact`

| Signal | Why it's safe |
|---|---|
| PR just merged | The work is on disk + GitHub; reasoning about that work is now noise |
| TaskList all completed | The plan is done; the steps don't need to stay in context |
| Exploration phase distilled into a plan / file | The plan is the artifact; raw exploration notes are noise |
| You're about to start an unrelated task | The previous task's reasoning would pollute the new one |
| Session has done >100 tool calls since the last `/compact` | Pure load-bearing reduction |

## When NOT to `/compact`

| Anti-signal | What you'd lose |
|---|---|
| Mid-implementation of a single file | Variable names, partial logic, the reason for an in-progress edit |
| Debugging a specific failure | The failure signature, attempted approaches that didn't work |
| Just received user feedback "actually, do it like X" | The exact phrasing of the feedback |
| Holding non-trivial state in memory that isn't yet on disk | TodoWrite items, planned next-steps that were verbalised but not written |

## What survives `/compact`

- Files on disk (re-read on demand)
- Git state (`git log`, `git status`)
- `CLAUDE.md` and auto-memory (re-loaded into the new context)
- `TaskList` items (state is preserved across compaction)
- The user's most recent few turns

## What does NOT survive `/compact`

- Mid-response reasoning chains
- Tool-result contents from many turns ago
- Implicit conventions you'd inferred but not yet written into CLAUDE.md / memory
- The exact failure message you debugged 20 turns back

## Pre-compaction checklist

Before you `/compact`:

1. Anything worth keeping that's not on disk? Write it.
   - If it's a project decision → memory entry
   - If it's a workflow → CLAUDE.md edit
   - If it's an in-progress plan → TaskWrite or a file
2. Anything you're mid-debug on? Either finish the debug, or write a short "state of debug" note before compacting.
3. Has the user given recent direction in chat? If yes, write it down (memory or CLAUDE.md) -- post-compact you'll have the gist, not the phrasing.

## Hook integration

`.claude/hooks/remind_strategic_compact.sh` (Stop hook) emits a one-shot proposal per signal-set when:

- `gh pr merge` was invoked **since the last `/compact`**, OR
- Tool-call count **since the last `/compact`** reached `STRATEGIC_COMPACT_TOOL_THRESHOLD` (default 100; refs #170)

Both counters re-baseline at every `compact_boundary` entry in the transcript jsonl (manual `/compact` or auto-compact), so the hook stops re-firing the moment you compact. Sessions that have never compacted fall back to whole-session counting (backward compatible).

The hook is non-blocking and only proposes -- it cannot run `/compact` itself (Claude Code hook output schema doesn't include that). Disable per-session with `STRATEGIC_COMPACT_DISABLE=1`.

## Anti-patterns

- **Compacting reflexively on every PR merge.** Only when the merged PR was the session's primary task. If the merge was an aside (e.g. a dependabot bump while working on something else), the rest of the context is still load-bearing.
- **Treating the hook as a command.** It's a nudge. You decide whether the boundary is real.
- **Compacting without writing down the latest user direction.** Post-compact you'll have to ask the user to repeat.
