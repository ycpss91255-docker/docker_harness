---
name: rebase-pr
description: Rebase and force-push a PR whose base branch moved so its CI re-runs against the updated main. Use when gh reports mergeStateStatus BEHIND (auto-merge stalled) or CONFLICTING (manual resolution required).
---

# rebase-pr

One-shot rebase + force-push for a PR whose base branch has moved
(`mergeStateStatus: BEHIND` or `CONFLICTING`). Issue #87.

## When to use

| Trigger | Action |
|---|---|
| `wait-pr-ci.sh` settles ALL_DONE but `gh pr merge` fails with "branch not up to date" | Rebase + force-push. |
| `gh pr view` shows `mergeStateStatus: BEHIND` | Rebase preemptively to avoid the failed merge round-trip. |
| `gh pr view` shows `mergeStateStatus: CONFLICTING` | Rebase manually; conflicts must be resolved by hand. |
| Routine "I want my PR rebased before merging" requests | One-shot via the script. |

Dependabot PRs do **not** use this skill -- prefer leaving
`@dependabot rebase` as a comment, which dependabot's own engine
handles correctly.

## CLI

```bash
.claude/scripts/rebase-pr.sh <pr> \
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
- `--dry-run` -- print planned actions; no fetch / rebase / push.

## Exit codes

| Exit | Meaning |
|---|---|
| `0` | Rebased + pushed (or `--dry-run` preview). |
| `1` | `git fetch` or `git rebase` failed for a non-conflict reason. |
| `2` | Rebase hit conflicts; manual `git rebase --continue / --abort` required. The script prints the conflicted file list + the exact recovery steps. |
| `3` | Pre-condition failure (PR not found, PR not OPEN, worktree not found). |

## Typical session

```
# wait-pr-ci.sh notified ALL_DONE; gh pr merge denied with "branch is not up to date"
.claude/scripts/rebase-pr.sh 105 --repo ycpss91255-docker/docker_harness

# Output:
#   rebasing PR #105 (fix/wait-pr-ci-skipped) onto origin/main in <workspace>/worktree/docker_harness-105
#   ... fetch / rebase progress ...
#   PR #105 rebased + pushed. Re-arm Monitor:
#     .claude/scripts/wait-pr-ci.sh --repo ycpss91255-docker/docker_harness --prs 105
```

After the script prints the re-arm hint, start a fresh `Monitor`
on the new head:

```
Monitor(
  description: "PR #105 CI (rebased)",
  command: ".claude/scripts/wait-pr-ci.sh --repo ycpss91255-docker/docker_harness --prs 105 [--check-filter <expr>]",
  timeout_ms: 1800000,
  persistent: false,
)
```

Stop the previous Monitor (if any) before the new one so the
notifications do not mix between heads.

## Conflict resolution (exit code 2)

When the rebase hits conflicts, the script does **not** attempt
automatic resolution. The known recurring patterns in this org
are documented for the human resolver:

1. **`doc/test/TEST.md` total counts** -- the `Total: **N tests**
   (...)` header gets bumped by both the PR and the just-merged
   commit. Resolution: take HEAD's new total and add the PR's
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
git rebase --continue
# repeat until rebase finishes
git push --force-with-lease
```

If unsure, abort: `git rebase --abort` and ask for help.

## Why `--force-with-lease` not `--force`

`--force-with-lease` refuses to push if the remote's head moved
since the local fetch -- this catches the case where someone
else pushed a new commit between our rebase and our push, which
plain `--force` would silently overwrite.

## See also

- `.claude/scripts/rebase-pr.sh --help`
- `.claude/skills/wait-pr-ci/SKILL.md` -- the polling sibling; its
  `FAIL` path mentions `rebase-pr.sh` when `mergeStateStatus`
  indicates a rebase is needed.
- `.claude/commands/pr.md` -- the full PR workflow.
- CLAUDE.md "Git 工作流程 > 主 checkout 狀態" -- the `git pull
  --ff-only` discipline that minimises stale-base rebases in the
  first place.
