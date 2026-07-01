---
name: update-stale-pr
description: Update a stale PR (BEHIND / CONFLICTING) by merging origin/main into the branch + a normal push, never rebase+force-push. Use when gh reports mergeStateStatus BEHIND (auto-merge stalled) or CONFLICTING (manual resolution required).
---

# update-stale-pr

One-shot merge-update + normal push for a PR whose base branch has
moved (`mergeStateStatus: BEHIND` or `CONFLICTING`). Issue #221.

`git rebase` is disallowed org-wide: a stale PR is refreshed by
**merging** the base branch into the PR branch and pushing
**normally** -- never rebase, never force-push. The
`enforce_merge_update_not_rebase.sh` PreToolUse hook denies `git
rebase` / `git pull --rebase`, and denies `git push --force*` on a
branch that has an open PR.

## When to use

| Trigger | Action |
|---|---|
| `wait-pr-ci.sh` settles ALL_DONE but `gh pr merge` fails with "branch not up to date" | Merge-update + normal push. |
| `gh pr view` shows `mergeStateStatus: BEHIND` | Merge origin/main in preemptively to avoid the failed merge round-trip. |
| `gh pr view` shows `mergeStateStatus: CONFLICTING` | Merge manually; conflicts must be resolved by hand. |
| Routine "I want my PR refreshed before merging" requests | One-shot via the script. |

Dependabot PRs do **not** use this skill -- prefer leaving
`@dependabot rebase` as a comment, which dependabot's own engine
handles correctly.

## CLI

```bash
.claude/scripts/update-stale-pr.sh <pr> \
  [--repo OWNER/REPO] \
  [--worktree PATH] \
  [--dry-run]
```

- `<pr>` -- the PR number. Required.
- `--repo` -- override `gh` repo resolution. Default: whatever `gh`
  picks from the current directory's remote.
- `--worktree` -- explicit worktree path. Default: scan
  `${WORKSPACE_DIR:-${PWD}}/worktree/*` for a checkout whose
  current branch matches the PR's head ref. Ambiguous matches
  (>1) are treated as "not found"; pass `--worktree` to
  disambiguate.
- `--dry-run` -- print planned actions; no fetch / merge / push.

## Exit codes

| Exit | Meaning |
|---|---|
| `0` | Merge-updated + pushed (or `--dry-run` preview). |
| `1` | `git fetch` / `git merge` failed for a non-conflict reason, or `git push` failed. |
| `2` | Merge hit conflicts; manual resolution required. The script prints the conflicted file list + the exact recovery steps. |
| `3` | Pre-condition failure (PR not found, PR not OPEN, worktree not found). |

## Typical session

```
# wait-pr-ci.sh notified ALL_DONE; gh pr merge denied with "branch is not up to date"
.claude/scripts/update-stale-pr.sh 105 --repo ycpss91255-docker/docker_harness

# Output:
#   updating PR #105 (fix/wait-pr-ci-skipped) by merging origin/main in <workspace>/worktree/docker_harness-105
#   ... fetch / merge progress ...
#   PR #105 merge-updated + pushed. Re-arm Monitor:
#     .claude/scripts/wait-pr-ci.sh --repo ycpss91255-docker/docker_harness --prs 105
```

After the script prints the re-arm hint, start a fresh `Monitor`
on the new head:

```
Monitor(
  description: "PR #105 CI (updated)",
  command: ".claude/scripts/wait-pr-ci.sh --repo ycpss91255-docker/docker_harness --prs 105 [--check-filter <expr>]",
  timeout_ms: 1800000,
  persistent: false,
)
```

Stop the previous Monitor (if any) before the new one so the
notifications do not mix between heads.

## Conflict resolution (exit code 2)

When the merge hits conflicts, the script does **not** attempt
automatic resolution. The known recurring patterns in this org
are documented for the human resolver:

1. **`doc/test/TEST.md` total counts** -- the `Total: **N tests**
   (...)` header gets bumped by both the PR and the just-merged
   commit. Resolution: take the incoming total and add the PR's
   delta on top.
2. **`doc/changelog/CHANGELOG.md` `[Unreleased]` ordering** --
   when a release PR promotes `[Unreleased]` -> `[vX.Y.Z]` and
   the PR adds its own entry, put the PR's `### Added` /
   `### Fixed` lines back under a fresh `[Unreleased]` block;
   leave the promoted `[vX.Y.Z]` below.

After fixing each conflict:

```
cd <worktree>
git add <fixed-files>
git merge --continue   # or: git commit
git push               # NORMAL push, no force
```

If unsure, abort: `git merge --abort` and ask for help.

## Why merge, not rebase + force-push

Rebasing rewrites the PR branch's history; force-pushing the result
discards the old head. That breaks review threads pinned to old
commits and throws away the CI record for the superseded head.
Merging `origin/main` in keeps the branch's history append-only, so
a normal `git push` fast-forwards the remote and review + CI history
stay intact. The `enforce_merge_update_not_rebase.sh` hook enforces
this: `git rebase` / `git pull --rebase` are denied, and
`git push --force*` is denied whenever the branch has an open PR.

## See also

- `.claude/scripts/update-stale-pr.sh --help`
- `.claude/hooks/enforce_merge_update_not_rebase.sh` -- the
  PreToolUse hook that denies rebase / open-PR force-push.
- `.claude/skills/wait-pr-ci/SKILL.md` -- the polling sibling; its
  `FAIL` path mentions updating a stale PR when `mergeStateStatus`
  indicates the base moved.
- `.claude/commands/pr.md` -- the full PR workflow.
