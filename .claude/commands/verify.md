Run the project's "變更完成 checklist" (CLAUDE.md) in one pass — shellcheck + hadolint + bats + tree audit + TEST.md drift + doc-scan + diff stats. Stop on the first hard failure (shellcheck / hadolint / bats); soft phases warn and continue.

Use this before `git commit` or before opening a PR, when the change touched code / scripts / Dockerfile / workflows / `.claude/**` — anything beyond pure prose. For pure README / CLAUDE.md prose edits, `/verify` is overkill; the relevant PostToolUse hooks already cover doc-only concerns.

## Invocation

`/verify` — run every phase in sequence against the current worktree.

`/verify $ARGUMENTS` — forward args to `.claude/scripts/verify.sh`. Useful flags:

- `--dry-run` — print the phase plan, run nothing.
- `--phase <name>` — run only one phase. Repeatable. Valid: `shellcheck`, `hadolint`, `bats`, `tree-audit`, `test-md`, `doc-scan`, `diff-stats`.
- `--continue-on-fail` — keep running soft phases after a hard phase fails. Exit code still reflects the worst phase.
- `--base <ref>` — diff base for `diff-stats` and `doc-scan` (default `origin/main`).
- `--repo-root <path>` — override repo root (default `${CLAUDE_PROJECT_DIR}` or `git rev-parse --show-toplevel`).

## How to read the output

Each phase prints `### <phase>` header then its raw output. At the end, a `## Verify summary` markdown table maps each phase to `pass` / `fail` / `skipped`.

- **All `pass`** — safe to commit / open PR.
- **Hard fail (shellcheck / hadolint / bats)** — exit 1. Fix before commit. By default, later soft phases are skipped; pass `--continue-on-fail` to see them anyway.
- **Soft fail (tree-audit / test-md / doc-scan)** — exit code still reflects, but you may legitimately know better (e.g. TEST.md will be updated in the same commit). Treat as a strong nudge.

## Pairing with other workflow steps

- After Claude edits files, the PostToolUse hooks (emoji / AI attribution / TEST.md drift / etc.) already fire per file. `/verify` is the batch version run once before commit / PR.
- `/doc-sync` is the broader 4-language README + emoji scan. `/verify` covers the mechanical CI subset (shellcheck / hadolint / bats / tree audit) plus TEST.md per-file drift; the two overlap on emoji + AI attribution scans but `/verify` only scans changed files vs `origin/main`, while `/doc-sync` walks every repo under the workspace.
- `/pr` step 3 ("Verify locally") is exactly this — invoke `/verify` instead of running `make` manually.

## Local-CI gate before PR (refs #176)

`enforce_local_full_ci_before_pr.sh` BLOCKS `gh pr create` / `gh pr ready`
unless local CI passed on the current HEAD. Running `make -C .claude/test test`
to green writes the marker `.claude/state/local-ci-pass/<HEAD-sha>.ok`
that satisfies the gate, so the canonical flow is: **verify green →
commit → open PR**. Committing docs (CHANGELOG / TEST.md / `doc/**` /
`*.md`) after the green run does NOT re-trigger the gate — the hook
allows a PR when only documentation changed since the last marker. To
skip the gate deliberately (accepting the GH-CI round-trip risk),
override for the exact HEAD: `LOCAL_CI_ACK=<sha> gh pr create ...`.

## Exit-code contract

The shell script `.claude/scripts/verify.sh` exits:

- `0` — all requested hard phases passed
- `1` — at least one hard phase failed
- `2` — usage / arg error

So `/verify && git commit` is safe shorthand for "verify hard phases passed before committing".

Context from user: $ARGUMENTS

Now run `.claude/scripts/verify.sh $ARGUMENTS` and report the markdown summary back. If any phase fails, surface the failing phase's raw output so the user can act on it directly.
