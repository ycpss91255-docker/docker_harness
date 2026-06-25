---
name: batch-mutation-pr
description: Generic cross-repo fanout engine — open one PR per downstream repo applying a caller-supplied mutation. Use instead of spawning a new one-shot batch-*.sh when you need the same file change across many repos.
---

# batch-mutation-pr

`.claude/scripts/batch-mutation-pr.sh` is the generic engine extracted
from the 10+ historical one-shot `batch-*.sh` / `fix-*.sh` /
`migrate-*.sh` scripts. They all repeat identical plumbing -- per repo:
fetch main, branch, mutate, commit, push, open PR -- and differ only in
the 5-10 line mutate step. That step is now your `--mutation` script;
the engine owns everything else.

**Before writing a new `batch-*.sh`, evaluate whether this engine plus
a small mutation script covers it.** Most micro-fanouts do not need a
fresh permanent script.

## Mutation contract

The engine invokes your mutation once per repo as
`<mutation> <repo-path>`, with the repo's new branch checked out under
`<repo-path>`. The mutation edits files in place and signals via exit
code:

| Exit | Meaning | Engine action |
|---|---|---|
| `0` | changed | commit + push + open PR |
| `3` | no-op / skip | drop the branch, no PR (idempotent re-runs land here) |
| other | error | record failure (honours `--continue-on-error`) |

The mutation's stdout/stderr is captured to a per-repo log and is NOT
engine output -- the engine owns the data product (the `_log_*` JSON
stream + the opened/skipped/failed summary). Keep mutations idempotent
so a second run no-ops cleanly.

## Usage

```bash
.claude/scripts/batch-mutation-pr.sh \
  --mutation /tmp/my-mutation.sh \
  --pr-title "chore: normalise X across repos" \
  --why-file /tmp/why.md \
  [--commit-type fix|feat|chore] [--branch <name>] \
  [--only r1,r2] [--skip r3] [--dry-run] [--continue-on-error]
```

Always `--dry-run` first to confirm the repo set and branch name. The
branch defaults to `<commit-type>/<slugified-title>`.

## Presets

`batch-line-edit.sh` is the first preset -- the most common micro-fanout
("append this one line to `<file>` in every repo if absent"):

```bash
.claude/scripts/batch-line-edit.sh \
  --file .gitignore --line "CLAUDE.md" \
  --why "stop the per-repo session symlink leaking into git status" \
  [--only ...] [--dry-run]
```

It generates an append-line-if-missing mutation (idempotent: a repo
already carrying the exact line exits 3 and is skipped) and delegates
to the engine. New presets follow the same shape: parse the
preset-specific args, generate a mutation, call
`batch-mutation-pr.sh`.

## When NOT to use

- Cross-repo `base`-tag fanout has its own dedicated path
  (`/batch-base-upgrade`); do not reimplement it here.
- Batch PR merge / close are separate primitives
  (`.claude/scripts/batch-pr-{merge,close}.sh`).
- Run from the main session, not a subagent -- subagent sandbox blocks
  `git push`.
