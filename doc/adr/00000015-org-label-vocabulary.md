# ADR-00000015: the org label vocabulary is five labels on two axes

- **Date:** 2026-09-03
- **Status:** Accepted
- **Relates to:** #91 (label required on issue create, hook rule 9),
  #278 (forcing an explicit scheduling answer),
  ADR-00000014 (planner / implementer separation -- what
  `ready-for-agent` gates)

## Context

Labels are the org's routing vocabulary: they decide what an issue is,
whether it is scheduled, and -- from this decision onward -- whether an
agent may implement it unattended. That makes them foundational, and
they were not defined.

Measured 2026-09-03 across `base`, `docker_harness`, `multi_run`,
`realsense_ros2` and `github_runner` (~500 issues):

```
enhancement      336
bug              126
documentation     34
backlog           19
triage            13
ready-for-agent    2
upstream           1
question           1
```

Never used at all: `accessibility`, `duplicate`, `good first issue`,
`help wanted`, `invalid`, `wontfix`.

The inventory itself had drifted badly. `base` carried 15 labels,
`docker_harness` 10, and `template`, `realsense_ros2`, `multi_run` and
`sam_manager` carried only GitHub's stock set with **zero** custom
labels. `template` is a GitHub template repository, and GitHub template
repositories do not copy labels, topics, branch protection or settings
-- only the file tree. So every repo created "from template" silently
skipped the whole `/new-repo` checklist, which is why the newest repos
are the emptiest.

`gh-artifact-format` meanwhile documented a "stock label inventory"
including `question` / `wontfix` / `invalid` / `duplicate` /
`good first issue` / `help wanted`, none of which any issue has ever
carried, and noted that cross-repo alignment was out of scope for #91.

## Decision

**Five labels, on two orthogonal axes. Nothing else is managed.**

### Axis 1 -- kind (exactly one, required at issue create)

| Label | Means |
|---|---|
| `bug` | A defect in shipped behaviour. Title prefix `fix(*)`. |
| `documentation` | Documentation only, no behaviour change. Title prefix `docs(*)`. |
| `enhancement` | **Work that is neither a defect fix nor documentation.** Title prefixes `feat(*)`, `refactor(*)`, `chore(*)`, `track(*)`. |

`enhancement` is defined by exclusion on purpose. GitHub's own
description calls it "new feature requests", but 336 of its uses are
features, refactors, chores and tracking issues together. Rather than
pretend otherwise or split it into buckets nobody filters on, the
definition is written to match the use. The title prefix carries the
finer distinction (`chore(hooks):` reads as a chore at a glance), so no
information is lost.

Hook rule 9 (#91) already requires exactly one of these at
`gh issue create`. PRs stay exempt -- they inherit from the issue they
close.

### Axis 2 -- state (optional, at most one)

| Label | Means |
|---|---|
| `backlog` | Deliberately not scheduled. An explicit answer, not silence. |
| `ready-for-agent` | The spec is complete enough for an agent to implement unattended. |

The two axes are independent: a `bug` may be `ready-for-agent`, an
`enhancement` may be `backlog`, and an issue may carry neither state
label -- which means the question has not been answered yet.

### `ready-for-agent` means four things are present

Not "someone felt good about it". The label asserts that the issue
contains, in a form an implementer can read without guessing:

1. **Seams** -- which files change, what the interface is.
2. **The first slice** -- the first failing test to write.
3. **The gate** -- the command that decides done.
4. **A bound** -- how many red-green cycles before stopping.

These are exactly what ADR-00000014's dispatch contract requires. An
implementer handed less has to invent the behaviour list, which is the
horizontal-slicing anti-pattern `/tdd` rejects.

This also gives `grilling` a completion condition: discussion ends when
those four can be written down, they are written back to the issue as a
comment (the body stays the original spec, per the
issue-scope-change-in-comments rule), and the label goes on.

### Two gates, not one

- **Applying the label** is checked: the four sections must exist.
- **Starting the pipeline** is checked again: the four sections must
  exist, regardless of the label.

These are two different questions -- "is the label honest" and "is this
safe to start" -- not the same check twice. Only the first would let a
hand-applied label through to an agent; only the second would let the
label decay back into decoration, which is what already happened (2 uses
since it was created).

### What is deliberately not managed

`triage` is dropped: in this design the absence of `ready-for-agent`
already means "not ready", so `triage` says the same thing twice and
makes the author hesitate over which to apply.

`upstream` is dropped: one use.

The six never-used GitHub defaults (`accessibility`, `duplicate`,
`good first issue`, `help wanted`, `invalid`, `wontfix`) are **left in
place and left unmanaged**. Deleting them means touching 24 repos and
GitHub recreates its defaults for new ones anyway; ignoring them costs
nothing. `good first issue` and `help wanted` presuppose external
contributors this org does not have; `accessibility` presupposes a user
interface; the close-decision labels are covered by GitHub's own close
reasons (`not planned`), which #212 was closed with.

`dependencies` and `github_actions` are created by Dependabot where it
is enabled, not by us. Managing them would make the drift check demand
them from repos that do not run Dependabot.

### Distribution -- both mechanisms, because each covers what the other cannot

| Concern | Mechanism |
|---|---|
| A new repo starts correct | GitHub org-level default labels (native, zero maintenance) |
| The 24 existing repos are brought into line | `labels.yaml` + `sync-labels.sh` |
| Someone edits or deletes a label later | drift cron, failing loudly |

GitHub's org defaults apply only at repository creation, and its own
documentation notes that anyone with write access can edit or delete the
labels afterwards -- so the native feature cannot cover backfill or
drift. The file-plus-sync-plus-cron half mirrors `topics.yaml` /
`sync-topics.sh` / `check-topics.yaml`, already proven in
`ycpss91255-docker/.github`, and keeps repository metadata under one
kind of source of truth rather than two.

## Consequences

- `gh-artifact-format` section 6 must be rewritten: its stock inventory
  lists six labels nothing uses, and its note that cross-repo alignment
  is out of scope is now false.
- `/new-repo` must point at the sync script instead of carrying manual
  label steps, and must say that creating a repo from `template` does
  not bring settings with it.
- Adding `ready-for-agent` becomes a checked action rather than a free
  one. That is the point, but it is friction at the moment of labelling.
- `labels.yaml` lives in `ycpss91255-docker/.github`; PRs there stall
  under auto-merge because a doc-only change plus a paths filter leaves
  the required check pending, so that one merges by hand.

## Alternatives considered

- **Keep the top five by usage** (`enhancement`, `bug`, `documentation`,
  `backlog`, `triage`). Rejected: it keeps `triage`, which the new state
  axis makes redundant, and drops `ready-for-agent`, whose low count
  reflects that nothing enforces it yet -- the very thing this decision
  changes.
- **Adopt GitHub's full default set including `accessibility`.**
  Rejected: "it is a platform default" is not a reason for a
  Dockerfile-and-shell org. GitHub's documentation recommends no labels
  beyond the defaults, so there is no external authority to defer to
  here; the set has to be justified by use.
- **Split `enhancement` into `chore` / `refactor`.** Rejected: it
  divides 336 issues into buckets nobody filters on.
- **Drop the kind axis entirely**, since the label is derived
  mechanically from the title prefix and duplication is the failure mode
  this org keeps repairing. Rejected on cost: it would change hook rule
  9 and the convention behind ~500 existing issues, in exchange for
  losing GitHub-side filtering and colour. The duplication is cheap and
  the derivation is one-directional.
