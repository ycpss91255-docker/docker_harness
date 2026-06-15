---
name: parallel-agents
description: Dispatch parallel Agent calls when a task targets 4+ independent repos / PRs / files instead of running serially. Use when the `remind_parallel_when_bulk.sh` UserPromptSubmit hook nudges, or on "process all repos / every X" prompts.
---

# parallel-agents

CLAUDE.md says: "for large workloads (multiple repos / multiple languages / batches of N), use parallel Agents instead of iterating." The paired `remind_parallel_when_bulk.sh` UserPromptSubmit hook fires when the user prompt has a bulk indicator; this skill is the rubric for whether and how to fan out.

## When to use parallel Agents

| Signal | Why it's a fit |
|---|---|
| `N >= 4` independent repos / PRs / files in the user prompt | Per-item work has no order constraint; wall-clock dominates |
| "all repos" / "every downstream" / "全部 X" | Same as above with an unspecified-but-large N |
| 4+ independent feature implementations | Each Agent can scope itself; no shared state |
| 4+ doc translations (one per language) | Pure read-then-write; trivially parallel |

**Max parallelism is 3** (per CLAUDE.md "工作量大時使用平行 Agent"). For N items, batch into groups of `ceil(N/3)` and dispatch one Agent per group.

## When NOT to use parallel Agents

| Anti-signal | What goes wrong |
|---|---|
| Sequential dependency (output of step K feeds step K+1) | Parallel agents race on the inputs they need |
| Shared state mutation (writing the same file from several Agents) | Last-writer-wins on the same path; lost work |
| Small N (1, 2, 3 items) | Setup + coordination cost exceeds the wall-clock saving |
| One-of-a-kind work (each item needs a custom plan) | Agents need self-contained instructions; bespoke per-item adds prompt-engineering overhead larger than the saving |
| Cross-repo batch that needs a `.claude/scripts/` permanent helper | That's a script job (`batch-base-upgrade.sh` shape), not an Agent job |

## How to dispatch

In a single message:

1. State the partitioning plan in one line ("split 11 repos into 3 Agents, 4/4/3").
2. Issue 3 (or up to 3) Agent tool calls in the same response. Each prompt is self-contained: target repos, what to do, what to report back.
3. Wait for all to complete; consolidate findings; report a single summary.

The Agent tool itself is the parallel dispatcher. **Multiple Agent calls in a single response run concurrently.** If you split into two responses, they run sequentially -- defeats the purpose.

## Prompt shape for each Agent

A parallel-Agent prompt should be reproducible without your context. Include:

- **Target list** -- the explicit repo / PR / file names this Agent owns.
- **Task** -- one paragraph; what to do, what NOT to do.
- **Output shape** -- "report a punch list: done / failed-with-reason".
- **Length cap** -- "under 300 words" to keep the consolidated summary readable.

Bad prompts ("based on your findings, fix the bug") push synthesis onto the Agent; good prompts ("for each repo in [A, B, C, D], run `just upgrade v0.32.0`, report PASS / FAIL per repo") keep the agent doing work, not deciding scope.

## Hook integration

`.claude/hooks/remind_parallel_when_bulk.sh` (UserPromptSubmit hook) emits a one-shot `systemMessage` per session when the user prompt matches any of:

- A number `N >= PARALLEL_REMIND_THRESHOLD` (default 4) followed by a plural noun in the bulk list (repos / PRs / issues / files / workflows / tests / hooks / directories / branches).
- "all" / "every" + a plural noun from the same list.
- An explicit comma- or newline-separated list of 4+ repo-shaped tokens.

Suppression: if the user prompt already mentions `parallel` / `平行` / `Agent` / `subagent` / `concurrent`, stay silent -- the user is already prompting for parallel work and a nudge would be noise.

Non-blocking; emits top-level `systemMessage`. Throttled once per session per signal-set (TMPDIR marker). Disable per-session with `PARALLEL_REMIND_DISABLE=1`.

## Anti-patterns

- **Spawning 4+ Agents** -- the cap is 3. Beyond 3, dispatch in waves.
- **Spawning Agents for trivially small N** -- 2 or 3 repos is faster to iterate inline; Agent setup cost exceeds saving.
- **Spawning Agents for sequential work** -- if Agent B needs Agent A's output, run them in one session, not in parallel.
- **Reusing the same prompt for every Agent** -- each Agent needs its own target list and scope; copy-pasting the global task wastes their context.
- **Forgetting to consolidate** -- after Agents return, write ONE summary; do not paste their raw reports unmerged.
