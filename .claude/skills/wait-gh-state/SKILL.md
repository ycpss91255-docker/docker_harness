---
name: wait-gh-state
description: Watch non-CI GitHub state transitions (issue close, release tag) via Monitor; sibling to wait-pr-ci
---

# wait-gh-state

Wait for a non-CI GitHub state transition before continuing -- an upstream issue closing, or a release tag appearing -- using `Monitor` so each transition streams in as a notification and the agent isn't blocked on busy-poll sleeps.

Two flavours, one script each:

| Flavour | Script | When |
|---|---|---|
| **Issue close** | `.claude/scripts/wait-issue-close.sh` | Adoption / fanout gated on an upstream issue closing (`base#367` closing before downstream PR opens). |
| **Release stable** | `.claude/scripts/wait-release.sh` | Waiting on a stable release tag after RC was cut (`base v0.32.0` after `v0.32.0-rc1`). |

Same Monitor invocation shape, same exit codes (`0` = triggered, `2` = arg error, `124` = max-iter), same per-transition snapshot + `---` output as the `wait-pr-ci` family.

### Cwd assumption (worktree gap, refs #63)

Like `wait-pr-ci`, the example Monitor blocks below use bare relative paths. Monitor inherits the agent's cwd at invocation. Ensure the cwd is the harness root or a `docker_harness` worktree before launching; if you're in a downstream-repo worktree, either `cd /home/.../docker && ...` or pass an absolute path inline.

## Issue close -- `wait-issue-close.sh`

```
Monitor(
  description: "issue#<N> close watcher",
  command: ".claude/scripts/wait-issue-close.sh --repo <OWNER>/<REPO> --issue <N> [--on-close \"<msg>\"]",
  timeout_ms: 3600000,           # human-paced; up to 1h
  persistent: false,
)
```

Polls `gh issue view <N> --repo <r> --json state,closedByPullRequestsReferences` every 30 min (override with `--interval`). Snapshot shape:

```
issue#<N>: state=<STATE>[ linked=PR#<n>,PR#<n>...]
---
```

`--on-close "<msg>"` appends a custom message right before exit 0 (handy for `next: open <downstream PR>` style hints).

## Release stable -- `wait-release.sh`

```
Monitor(
  description: "release v0.32.x watcher",
  command: ".claude/scripts/wait-release.sh --repo <OWNER>/<REPO> --tag-pattern '<POSIX-ERE>' [--on-stable \"<msg>\"]",
  timeout_ms: 3600000,
  persistent: false,
)
```

Polls `gh release list --repo <r> --limit 5 --json tagName`, filters by `--tag-pattern` (POSIX ERE), classifies each new tag as `rc` (substring `-rc`) or `stable` (no `-rc`). Snapshot shape:

```
release: <tag> (stable|rc)
---
```

Each tag emits once (dedup across iterations). RC tags keep polling. First stable tag exits 0.

Tag pattern shapes:

| Pattern | Matches |
|---|---|
| `^v0\.32\.[0-9]+$` | stable only (`v0.32.0`, `v0.32.1`, ...; excludes `-rc`) |
| `^v0\.32\.` | rc + stable (`v0.32.0-rc1`, `v0.32.0`, ...) |

Use the loose form when you want RC visibility; use the strict form when only stable matters.

## Behaviour (both scripts)

- Each state transition prints exactly one snapshot block. Steady states print nothing.
- Default poll interval is 1800 s (30 min) since issue / release state is human-paced.
- Exit 0 means the awaited transition happened. Exit 124 means `--max-iterations` exhausted (test-only cap; production callers leave it unset).
- Code 1 (in-band failure) is not used -- "issue stays OPEN forever" or "no stable tag" are valid waits, not failures.

## Anti-patterns

- **Hand-rolling 20-line inline Monitor bodies** with `seen=":"` sets, `case` to dodge Monitor's `!` escaping, and `sleep 1800` -- exactly the pattern this skill collapses. Use the script.
- **Reaching for `wait-pr-ci.sh` to watch issue close** -- different query shape; won't fit.
- **Using `gh run watch` for issue / release state** -- that's CI-run-scoped; not applicable here.

## Pairing with adoption / fanout

Once `wait-issue-close.sh` exits 0, the downstream PR is now safe to open / `gh pr merge --auto`. Once `wait-release.sh` exits 0 on a stable tag, `/batch-base-upgrade` (or downstream `just upgrade <tag>`) can run.

## See also

- `.claude/scripts/wait-issue-close.sh` / `.claude/scripts/wait-release.sh` -- the polling implementations. `--help` prints usage.
- `.claude/skills/wait-pr-ci/SKILL.md` -- sibling skill covering CI rollups + workflow runs.
- CLAUDE.md "## 主動優化建議 / 任務結束時主動列 skill 化候選" -- the rule that surfaced this skill from the four hand-rolled monitors in `ros1_bridge#107` session.
