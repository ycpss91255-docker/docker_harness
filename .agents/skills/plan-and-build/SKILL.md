---
name: plan-and-build
description: Split a task into a planning half you do with the user and an implementation half an autonomous Workflow agent runs in a worktree under /tdd. Use when a task is big enough to plan explicitly and mechanical enough to hand off once the seams are fixed.
---

# plan-and-build

The session the user talks to is the **planner**. Implementation is delegated
to a **Workflow-spawned agent** working in an isolated git worktree, following
`/tdd`. The planner keeps judgement; the implementer keeps typing.

This skill is a **thin sequencer** over artifacts that already exist. It adds a
handoff contract, not new machinery:

`grill-me` -> `to-issues` -> `tdd` -> `/pr` -> `auto-merge-on-green` -> `/verify`

## When to use

| Fits | Does not fit |
|---|---|
| The seams are decidable up front, the rest is mechanical | The design is still moving -- grill first, hand off after |
| A gate command exists that proves done (`just ... check`) | No executable definition of done |
| One planned task at a time | Fanning out several concurrent implementers (out of scope, refs #267) |
| A one-line typo fix | Cheaper to just do it |

## Measured ground truth (2026-08-04)

Two probes established what an autonomous implementer can actually do here.
Do not re-derive these:

- A Workflow-spawned agent ran `git add` / `git commit` (commit landed),
  `docker ps` and `just --version` with **zero permission prompts, zero
  sandbox denials, zero hook blocks**.
- The same kind of agent ran `just -f <worktree>/.claude/test/justfile check`
  inside a fresh worktree: **exit 0, `1..1065`, 1065 ok / 0 not ok, 96 s**.

The per-command prompting recorded for Agent-tool subagents does **not** apply
to Workflow-spawned agents.

## The planner's half

1. **Fix the seams, not the whole behaviour list.** `/tdd` names writing every
   test up front as the horizontal-slicing anti-pattern and requires each test
   to respond to the previous cycle. So hand over:
   - the interface / seams,
   - the gate command,
   - the **first slice only**.

   The implementer derives subsequent slices per cycle. Handing over a complete
   behaviour list would be the anti-pattern, in the planner's handwriting.

2. **File the tracking issue** (`to-issues` shape, 5 sections per
   `gh-artifact-format`). This is the GitHub-side record: the body carries the
   milestone list, one `- [ ] #NNN` line per sub-issue when the work splits.

3. **Create the worktree yourself.** `check_main_fresh_before_worktree.sh`
   denies a stale base, so the planner refreshes `main` first. The implementer
   never creates branches or worktrees -- see Containment below.

## Dispatching the implementer

Two templates live in this directory; fill the CONFIG block and pass the result
as `Workflow({script: ...})`.

| Template | Use when |
|---|---|
| [`workflow-template.js`](workflow-template.js) | One implementer drives a planned slice-chain to green |
| [`review-loop-template.js`](review-loop-template.js) | Fix and review alternate over an existing branch, and the run decides whether it may be published -- see [The review loop](#the-review-loop) |

Both encode the contract below; they live here rather than in a new
`.claude/workflows/` directory, which would add a CONTEXT.md obligation with
no lint behind it (`check-claude-md-tree.sh` audits `commands/` / `scripts/` /
`hooks/` only).

The prompt must be self-contained. Include:

- **The worktree path and which repo it belongs to.** `agent/*`, `app/*`,
  `env/*` are separate sibling repos; a docker_harness worktree contains none
  of their files.
- **`/tdd` by the workspace path**, e.g.
  `/home/yunchien/workspace/docker/.claude/skills/tdd/SKILL.md`, or the
  unscoped skill name. It is **not reachable via the worktree path**: `tdd` is
  a machine-local third-party install (ADR-00000011) and is not reproduced
  inside worktrees. Touching a worktree also registers
  `worktree/<name>:<skill>` variants, so a bare "use skill X" is ambiguous.
- **The gate command, verbatim**, and an instruction to tail rather than read
  its output whole (a full `check` run prints ~59 KB).
- **The stopping condition** (below), stated as a hard bound.
- **Repo conventions do not travel.** State them: `just` recipes rather than
  raw `docker`; English-only git artifacts; no AI attribution.

## Stopping condition

Bound every run by red-green cycle count **and** wall clock. On exhaustion the
implementer posts a handoff comment on the issue and **stops** -- it does not
retry silently. `just ... check` proves the tests pass; it cannot prove the
implementation is right, so an unbounded loop converges on plausible-looking
green, not on correct.

## The review loop

When a run alternates fix and review over an existing branch rather than
driving one implementer to green, use
[`review-loop-template.js`](review-loop-template.js) instead. It is the same
handoff contract with three additions, and all three are load-bearing.

**A land gate that can only refuse has no fixed point.** Writing the land
phase as `if (review.closed)` gives it exactly one direction. It cannot decide
that a round's findings are not about the branch under review, so reviewers
open new findings faster than they close the round's own, the budget runs out,
and the script exits with the branch complete and unpublished. That is what
produced three finished branches sitting unpushed for hours while the
open-issue count was the only number moving (base#1003).

**Scope is decided before a finding can gate, by two questions with a
default.** Same shape as PRD invariant 11.

| | Question | Verdict |
|---|---|---|
| Q1 | Did this branch introduce it -- a defect in a line it wrote, or a false claim in its own commit message or PR body? | **In scope.** Never deferrable. |
| Q2 | Is it the unfixed sibling of a shape this branch did change -- the mirrored scaffold, the commented copy, the other physical line of the same statement? | **In scope.** Half a shape fixed is a new defect. |
| -- | Anything else: a pre-existing defect noticed while reading, the same class at an untouched site, a follow-up this change makes visible, a neighbouring module | **Out of scope**, and this is where an uncertain call goes. |

**Why the default is "out".** Nothing is lost by it, because an out-of-scope
finding is filed as an issue and cross-referenced from the PR body *before* the
branch is published. The deferral is recorded and recoverable. The opposite
default loses the branch itself, behind a bar the next round raises again.
Losing a finding is the failure a follow-up issue prevents; never landing is
the failure nothing prevents. Q1 is what stops the default being abused.

**Budget exhaustion is a reported failure, and accounting is unconditional.** A
run that ends with in-scope findings still open names the branch, the HEAD sha
and the open findings. A run that ends holding unpushed commits reports them
whatever the reason -- so the accounting phase sits *outside* the loop, on
every path out of the script.

That last point is not stylistic. A workflow script has no filesystem access,
so "did this run leave work behind" cannot be inferred from control flow; it
has to be read off the worktree by an agent. Skip that read on any path and
the run exits identically to one that had nothing to do -- which is worse than
an error, because it looks like completion.

## Landing the work

- The **planner** opens the PR. `/pr` step 5 shape; the PR body is the
  canonical decision record and needs `## Resolution` or `## Decision` when it
  closes an issue.
- **Auto-merge is armed on open, same as any other PR here** -- green CI lands
  it without a separate ask. Autonomously produced code is held to the repo's
  standing bar, not a stricter one. What carries the risk is therefore the
  gate: it must actually discriminate, because nothing downstream will.
- The stopping condition below is what keeps "green" meaningful. A run that
  grinds toward a passing test rather than a correct one must hit its bound
  and stop, not keep going until the gate happens to agree.

**A bug found after merge is a gate defect, not a review failure.** The fix is
to add the test that would have caught it, so the gate is strictly stronger
than it was -- not to insert a human read-through that the next bug would slip
past just as quietly. Treat every escape as the gate telling you where it is
thin.
- `enforce_local_full_ci_before_pr.sh` wants a marker written by
  `ci-and-stamp.sh` for the exact HEAD; that runs planner-side.

## Containment (why the implementer's scope is narrow)

Gates such as `enforce_worktree_for_branch` / `enforce_batch_via_script` /
`enforce_wrapper_first_upgrade` exist to confirm **human** intent, and are
lifted by an ack file that any agent could create. There is no reliable signal
separating an autonomous agent from the interactive session --
`CLAUDE_CODE_CHILD_SESSION=1` and `session_id` are identical in both -- so the
separation cannot be enforced technically today.

It is therefore enforced by **scope**: the implementer edits files, runs the
gate, and commits inside a worktree the planner already made. It does not
create branches or worktrees, does not run batch scripts, does not upgrade
`.base`, and does not open or merge PRs. Anything that would trip a
human-intent gate stays planner-side, where the human is present.

An implementer that reports it needs one of those operations is reporting a
planning gap. Fix the plan; do not have it ack its way through.

## Recording progress on GitHub

Reuse the epic pattern already in this org:

- Issue body = the original spec. **Do not rewrite it to tick checkboxes** --
  the body is fixed at filing, and evolution is recorded in comments.
- One progress comment per milestone.
- PR body = canonical decision record.
