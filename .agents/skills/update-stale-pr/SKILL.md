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
- `--dry-run` -- print planned actions; no fetch / merge / push. If a
  merge is already in progress, classify its conflicts and print the
  verdict instead, writing nothing.

## Exit codes

| Exit | Meaning |
|---|---|
| `0` | Merge-updated + pushed (or `--dry-run` preview). |
| `1` | `git fetch` / `git merge` failed for a non-conflict reason, or `git push` failed. |
| `2` | Merge hit conflicts that are not pure count drift; manual resolution required. The script prints the per-file classification, why the tree was refused, the conflicted file list and the exact recovery steps. |
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

## Conflict resolution

Exactly one conflict class is resolved automatically, and nothing else
(issue #287).

A conflict hunk is **regenerated** when its two sides are identical once
every digit run is masked -- the shape you get when both branches added
tests and both rewrote the same derived total:

```
<<<<<<< HEAD
Template self-tests: **3111 tests** total (2964 unit + 147 integration).
=======
Template self-tests: **3093 tests** total (2946 unit + 147 integration).
>>>>>>> origin/main
```

Neither figure is right after the merge. The right one is what
`.claude/scripts/sync-doc-test-counts.sh` computes from the merged tree,
so the script drops the markers, re-runs the generator, stages the
result and commits -- then pushes as usual. It prints the file, the hunk
count and the before / after figures, so the landed number is visibly
recomputed rather than chosen.

Two guards bound it, and both refuse the WHOLE tree rather than part of
it:

- **Every hunk must be regenerated.** One prose hunk anywhere and
  nothing is resolved. Taking `--ours` / `--theirs` wholesale on these
  files has twice swallowed hand-written prose from an adjacent hunk;
  that is the failure being designed out.
- **Every conflicted file must be one the generator writes.** The set
  comes from `sync-doc-test-counts.sh --list-outputs`, asked at run
  time -- never a list kept in the script. A numeric-looking conflict in
  a file nothing recomputes is a real conflict.

`--dry-run` on a worktree that is already mid-merge prints the same
classification and stops, which is the fastest way to see WHY a tree was
refused.

### When it exits 2 (manual)

Recurring patterns worth knowing:

1. **`doc/changelog/CHANGELOG.md` `[Unreleased]` ordering** -- when a
   release PR promotes `[Unreleased]` -> `[vX.Y.Z]` and the PR adds its
   own entry, put the PR's `### Added` / `### Fixed` lines back under a
   fresh `[Unreleased]` block; leave the promoted `[vX.Y.Z]` below.
2. **Catalogue rows beside the counts** -- resolve section by section,
   never with `--ours` / `--theirs` on the whole file.

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
- `.claude/scripts/sync-doc-test-counts.sh --list-outputs` -- the
  generator's own answer to "which paths do you own", and the only
  source of the auto-resolution allowlist.
- `.claude/hooks/enforce_merge_update_not_rebase.sh` -- the
  PreToolUse hook that denies rebase / open-PR force-push.
- `.claude/skills/wait-pr-ci/SKILL.md` -- the polling sibling; its
  `FAIL` path mentions updating a stale PR when `mergeStateStatus`
  indicates the base moved.
- `.claude/commands/pr.md` -- the full PR workflow.
