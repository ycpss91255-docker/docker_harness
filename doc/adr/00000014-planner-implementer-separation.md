# ADR-00000014: planner / implementer separation runs on Workflow, not the Agent tool

- **Date:** 2026-08-04 (amended 2026-08-06, refs #274)
- **Status:** Accepted
- **Relates to:** issue #267 (the `plan-and-build` skill),
  ADR-00000011 (split skill tracking -- why `tdd` is not in worktrees),
  ADR-00000002 (the `/tmp` checkpoint ack protocol this constrains)

## Context

The session a user talks to should plan; implementation should be
delegated to an autonomous agent working in an isolated worktree under
`/tdd`. Whether that is possible at all turned on one question: does an
autonomous agent get to work uninterrupted, or does the user have to
approve each mutating command?

The prior belief, recorded 2026-06-26, was that it does not: subagents
could run docker/git/gh, but each command raised a permission prompt, so
"plan once, walk away" was impossible and mutation had to stay in the
main session. That belief was formed against the **Agent tool**.

Two probes on 2026-08-04 tested it against the **Workflow tool**:

- A Workflow-spawned agent appended to a scratch repo, ran `git add` and
  `git commit` (the commit landed), `docker ps`, and `just --version`:
  **zero permission prompts, zero sandbox denials, zero hook blocks.**
- The same kind of agent ran the real gate,
  `just -f <worktree>/.claude/test/justfile check`, inside a fresh
  worktree at `origin/main`: **exit 0, `1..1065`, 1065 ok / 0 not ok,
  96 s.**

The second probe also settled a related worry. `.claude/settings.local.json`
is gitignored, so a worktree does not carry the sandbox exemptions, and the
prediction was that `just` (absent from `excludedCommands`) would be
sandboxed and lose the docker socket. It was not: agents run with the
**session's** settings, not the worktree's -- their cwd is the workspace.

## Decision

**Implementation is delegated through the Workflow tool.** The Agent tool
is for read-only work: research, analysis, review.

**Human-intent gates are enforced against agents in the hook payload, not
the environment.** `auto_allow_touch_ack.sh` auto-allows the one-click ack
that lifts the Tier 2 E2 gates (`enforce_worktree_for_branch` /
`enforce_batch_via_script` / `enforce_wrapper_first_upgrade`). An agent
able to write its own ack lifts those gates rather than passing them. Hooks
do fire for subagent tool calls, and a subagent payload carries `agent_id`
/ `agent_type` that a main-session payload does not, so the hook keys on
those and **denies** agent callers outright.

The first attempt (#267) had the hook stay *silent* for agent callers, on
the reasoning that the ack would then fall through to the normal ask flow
and a human would answer it. A runtime check refuted that: a Workflow agent
created the ack file uninterrupted. With no hook decision the permission
layer judges a bare `touch` of a `/tmp` path benign and approves it without
asking, so silence is indistinguishable from consent. An explicit deny is
what returns the decision to the human (#274). The lesson generalises --
**a hook that declines to decide has not withheld permission.**

The environment cannot serve this purpose: `CLAUDE_CODE_CHILD_SESSION` is
`1` in the interactive session too, and `session_id` is identical for
parent and child. Both were measured, not assumed.

**Containment by scope remains, as the primary line.** The implementer
edits files, runs the gate and commits inside a worktree the planner
already created. It does not create branches or worktrees, run batch
scripts, upgrade `.base`, push, or open or merge PRs. Everything that
would trip a human-intent gate stays planner-side, where the human is.
The ack fix is the backstop for that scope being violated, not a licence
to widen it.

**The gate is the only quality mechanism, so it must carry that weight.**
Auto-merge is armed on open, the same as any other PR here; autonomously
produced code is held to the repo's standing bar, not a stricter one. A
bug found after merge is therefore treated as a **gate defect**: the
response is the test that would have caught it, making the gate strictly
stronger, not a human read-through that the next bug would slip past just
as quietly. What keeps "green" meaningful is the hard red-green cycle
bound -- a run that grinds toward a passing test rather than a correct one
must stop at its bound and report, instead of continuing until the gate
happens to agree.

**The planner hands over seams, the gate, and the first slice only.**
`/tdd` names writing the full behaviour list up front as the
horizontal-slicing anti-pattern and requires each test to respond to the
previous cycle. A planner-authored complete behaviour list would be that
anti-pattern in the planner's handwriting, so subsequent slices are
derived by the implementer.

## Consequences

- Dispatch prompts must reference `tdd` by its **workspace** path. Per
  ADR-00000011 it is a machine-local third-party install and is not
  reproduced inside worktrees; `<worktree>/.claude/skills/tdd/SKILL.md`
  does not exist. Touching a worktree also registers
  `worktree/<name>:<skill>` variants, so a bare skill name is ambiguous.
- Repo conventions do not travel with a subagent. Prompts must restate
  them: `just` recipes over raw docker, English-only git artifacts, no AI
  attribution, red/green commit splits.
- Gate output is large (~59 KB for a full `check`); implementers must tail
  or grep rather than read it whole.
- The `plan-and-build` skill is a thin sequencer over `grill-me` ->
  `to-issues` -> `tdd` -> `/pr` -> `auto-merge-on-green` -> `/verify`. Its
  value is this contract; it deliberately adds no new machinery, and its
  Workflow template lives in the skill directory rather than a new
  `.claude/workflows/` (which would carry a CONTEXT.md obligation with no
  lint behind it -- `check-claude-md-tree.sh` audits `commands/` /
  `scripts/` / `hooks/` only).

## Alternatives considered

- **Keep implementation in the main session** (the 2026-06-26 position).
  Rejected: it was premised on per-command prompting that does not apply
  to Workflow-spawned agents.
- **A PreToolUse hook blocking edits in the planner session.** Rejected in
  the design grill: role separation is workflow discipline, not a
  correctness invariant, and such a hook would need exceptions for plan
  docs, specs, issue bodies, memory and typo fixes. Every BLOCKing hook in
  this repo guards a correctness invariant; reminders are `remind_*`.
- **Detecting agents by environment variable.** Rejected on measurement:
  no environment variable distinguishes them.
- **Requiring human review before merge.** Rejected by the repo owner:
  it splits the standing bar in two and leans on a read-through rather
  than on the gate. Escapes are fixed in the gate instead.
