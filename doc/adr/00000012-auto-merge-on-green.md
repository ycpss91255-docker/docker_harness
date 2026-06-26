# ADR-00000012: Auto-Merge-on-Green — Hook Reminds, Skill + GitHub Land

- **Date:** 2026-06-26
- **Status:** Accepted

## Context

Opening a PR and landing it was a manual three-step dance in `/pr`:
arm `gh pr merge --auto` (step 5), then `wait-pr-ci` to watch CI (step
6), then -- if `main` moved and the branch went `BEHIND` under `strict`
branch protection -- a manual local `git pull --rebase` + force-push to
unblock auto-merge. In practice the arm step was often skipped and PRs
were merged by hand.

`ycpss91255/initialization#154` / PR `#155` had already designed and
validated (via a grilling session) an `auto-merge-on-green` skill that
packages this: a script that arms GitHub-native auto-merge, polls
`mergeStateStatus`, and nudges `BEHIND` branches with `gh pr
update-branch`. Issue #211 ports it to this repo.

Two facts shaped the port:

1. **This repo already has GitHub-native auto-merge.** `allow_auto_merge`
   is on; `/pr` already calls `gh pr merge --auto --squash
   --delete-branch`. So the increment here is *automating* the manual
   `BEHIND` handling + terminal-state detection and *packaging* it as a
   skill + reminder, not introducing auto-merge.
2. **This repo's CI-watch reminder umbrella is richer than
   initialization's.** Three PreToolUse hooks already split the
   triggers: `gh pr create` (remind_pr_wait_ci), `git push` re-push
   (remind_monitor_on_git_push, with careful `-u`/`main`/tag
   exclusions), and `gh workflow run` / `gh run rerun`
   (remind_monitor_on_ci_trigger). initialization broadened a single
   hook to `gh pr create` + `git push`; doing that here would
   double-fire with the existing git-push hook and lose its exclusions.

## Decision

- **Division of labour: hook detects + instructs; skill + agent
  execute; GitHub merges.** Hooks are synchronous and short-lived -- they
  cannot run a Monitor or merge. The reminder injects the instruction;
  the agent wraps `.claude/scripts/auto-merge-on-green.sh` in one
  Monitor; GitHub lands the PR server-side (so it merges even if the
  session ends).
- **`mergeStateStatus`-keyed script**, so it is repo-agnostic (no
  hardcoded check name -- this repo's required check is
  `bats + shellcheck + hadolint`). `MERGED` -> exit 0; `BEHIND` ->
  `gh pr update-branch` + keep polling; `DIRTY` -> exit 1 (rebase
  needed); required-check `FAILURE` while `BLOCKED` -> exit 1 with
  auto-merge **left armed** (a fix-push lands it); non-progressing
  `BLOCKED` past a `--grace` window (default 90s) -> exit 1. Exit-code
  contract (0/1/2/124) matches the `wait-pr-ci` siblings.
- **Keep the three-hook umbrella; re-point messages by context instead
  of merging hooks.** `remind_pr_wait_ci.sh` is renamed to
  `remind_ci_auto_merge.sh` (still `gh pr create`-only) and points at
  `auto-merge-on-green`. `remind_monitor_on_git_push.sh` keeps its
  trigger + exclusions and only updates its message to
  `auto-merge-on-green` (arm is idempotent on re-push).
  `remind_monitor_on_ci_trigger.sh` is unchanged (tag / dispatch
  context, not a PR-land). This diverges from initialization's
  single-hook broadening, justified by this repo's pre-existing richer
  umbrella -- it avoids double-firing and preserves tested exclusions.
- **`auto-merge-on-green` is the canonical "land a single PR" flow;
  `wait-pr-ci` stays a pure monitor** for tag CI, batch CI, and
  "wait-then-do-dependent-work" (non-merge) cases. `/pr` steps 5-6 point
  at the skill.
- **No human-review guard.** Branch protection requires 0 reviews;
  human oversight moves to feature / project checkpoints. The merge
  decision is the required check only.

### Not ported (deliberately out of scope)

- **CI re-trigger** (`--retrigger-grace`: push an empty commit when the
  head has no CI run). initialization added it later; it mutates history
  (an empty commit) and was not part of the #211 grill. The
  "pushed-but-no-CI" race is rare here; leave it for a follow-up if it
  proves needed.
- **GitHub merge queue** (would close the session-gone + later-`BEHIND`
  stall). Out of scope.

## Consequences

**Good:**

- The manual `BEHIND` rebase + force-push step is automated via
  `gh pr update-branch`. One Monitor covers arm + watch + land.
- `mergeStateStatus`-keyed, so the same script works on base /
  downstream repos without a per-repo check-name table.
- The CI-watch umbrella keeps its precise triggers; no double-firing.

**Bad / risks:**

- Degraded case: if the session ends AND the branch later goes `BEHIND`,
  GitHub native auto-merge stalls until someone runs
  `gh pr update-branch` (a merge queue would close this; out of scope).
- The `.github` org-profile repo's doc-only PRs leave required checks
  permanently pending (paths filter) -> auto-merge stalls; merge those
  manually (documented in the skill).

**Reversal cost:** low. Re-pointing the two reminder messages back at
`wait-pr-ci` and dropping the skill + script restores the prior flow;
nothing else depends on it.

## References

- Issue ycpss91255-docker/docker_harness#211
- ycpss91255/initialization#154 / #155 (the validated design this ports)
- `.claude/scripts/auto-merge-on-green.sh` (`--help`) +
  `auto-merge-on-green` skill
- ADR-00000007 (slash-command-first — same "package the flow behind a
  named artifact" flavour)
