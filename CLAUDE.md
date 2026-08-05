# CLAUDE.md

This file is the working-memory contract for Claude Code sessions in
this repo. Domain knowledge lives in [`CONTEXT.md`](CONTEXT.md);
historical rationale lives in [`doc/adr/`](doc/adr/). New material
should land in one of those two, not here -- size of this file is
load-bearing because it ships in every session's system prompt.

The `## Workflows` section below is the navigation table: each row
points at the skill or slash command that owns the workflow. Open the
linked artifact for the actual procedure.

## 專案概述

Docker container management + configuration collection. Templates for
ROS robotics development, AI tooling integration, and application
deployment. All repos under the `ycpss91255-docker` GitHub org.

## 檔案命名慣例

**The standard name is ours; a suffix marks a local variant.** Ours =
shipped or generated, replaced on update, not hand-edited per
instance -- `Dockerfile`, `compose.yaml`, `.env`. Suffixed = the
user's / operator's, never touched by tooling -- `.env.local`, which
overrides `.env` and enters the container alongside it.
`.env.generated` is ours despite the suffix: it is an interpolation
cache that never enters the container, so the suffix marks a category,
not ownership. See §1 of the workspace-root `CONTEXT.md`.

- Traditional Chinese README: **`README.zh-TW.md`** (hyphen, not
  underscore)
- English README: `README.md`
- Docker Compose: `compose.yaml` (not `docker-compose.yaml`)

## 目錄結構

See §2.1 of the workspace-root `CONTEXT.md` for the full directory
tree (`docker/` top-level + `.claude/` internals). The
`check-claude-md-tree.sh` lint diffs that listing against the
filesystem.

## 常用指令

Container ops (downstream repos; recipes imported top-level, args
without `--`):

```bash
just build            # build devel image  (e.g. just build test | just build --no-cache)
just run              # interactive run    (e.g. just run -d)
just exec             # exec into container (e.g. just exec -t bats-src bash)
just stop             # stop + remove containers
just setup            # regenerate .env + compose.yaml (just setup-tui = menu)
just upgrade [vX.Y.Z] # upgrade .base/ subtree
```

Base self-test:

```bash
just test                  # base self: bats + shellcheck + hadolint (+ kcov)
just test lint             # shellcheck + hadolint only
just -f .claude/test/justfile check # docker_harness harness (CI runs .claude/test/ci.sh)
```

For flags/overrides read `<cmd> -h` or bare `just` first. Legacy
downstream not yet fanned out may still use `make <verb>`.

## 標準容器結構

See §2.2 of the workspace-root `CONTEXT.md` for the per-repo file
layout (Dockerfile / compose.yaml / wrapper symlinks / `.base/`
subtree / `doc/` / `test/bats/` / etc.).

## Git 設定

```bash
git config user.name "<your-name>"
git config user.email "<your-email>"
```

GitHub organisation: `ycpss91255-docker`.

## Workflows

Each row points at the skill (`[[name]]`) or slash command (`/cmd`)
that owns the workflow. Read the linked artifact, do not re-derive
from prose.

- Change-completion checklist (lint + bats + doc sync): `/verify`
- Doc alignment (CHANGELOG / TEST.md / README sweep): `/doc-sync`
- TDD red-green-refactor: `[[tdd]]`
- Bug fix / new feature / refactor PR: `/pr`
- Cross-repo base-tag fanout: `/batch-base-upgrade`,
  `/batch-pr` (close / merge variants under
  `.claude/scripts/batch-pr-{merge,close}.sh`)
- Version bump + RC + release tag: `[[semver-bump]]` (canonical
  primitive: `.claude/scripts/release-tag.sh`)
- `.base` subtree upgrade: `just upgrade [vX.Y.Z]` (downstream) /
  `just ci upgrade` (base self); wrapper-first, raw
  `./.base/upgrade.sh` and `git subtree pull` are BLOCKed by
  `enforce_wrapper_first_upgrade.sh` (legacy `make -f Makefile.ci
  upgrade` still accepted during the make->just transition)
- New repo creation under the org: `/new-repo`
- Land a PR after open (arm GitHub auto-merge + Monitor):
  `[[auto-merge-on-green]]`; pure CI monitoring (no merge):
  `[[wait-pr-ci]]` (PR / tag) or `[[wait-gh-state]]` (issue close /
  release tag)
- Update a stale PR (BEHIND / CONFLICTING) via merge origin/main
  (no rebase/force): `[[update-stale-pr]]`
- gh issue / PR artifact format (titles / body / close / comment /
  cross-ref): `[[gh-artifact-format]]` (enforced by
  `enforce_gh_body_file.sh`)
- ADR creation when a design rationale lands: `/adr`
- Safe delete (trash instead of rm): `/safe-delete`
- Triage issues / batch issue grooming: `/issue-check`, `/issue-fix`
- Strategic `/compact` at task boundary: `[[strategic-compact]]`
- Proactive optimisation candidates at boundary:
  `[[proactive-optimization]]` (Stop hook reminds)
- Skillification candidates at wrap-up:
  `[[skillification-candidates]]` (Stop hook reminds)
- Parallel-Agent dispatch for bulk work (N>=4 independent items, cap
  3): `[[parallel-agents]]` (UserPromptSubmit hook reminds)
- Plan with the user, then hand implementation to a Workflow agent in
  a worktree under `/tdd`: `[[plan-and-build]]` (ADR-00000014)
- Stress-test plan / design before commit: `[[grill-me]]` (Q&A) or
  `[[grill-with-docs]]` (Q&A that also updates CONTEXT.md / ADR
  inline as decisions crystallise)
- Break a plan / PRD into independently-grabbable issues: `[[to-issues]]`
- Diagnose hard bugs / performance regressions (reproduce → minimise
  → instrument → fix → regression-test): `[[diagnosing-bugs]]`
- Throwaway prototype to flesh out a design before committing:
  `[[prototype]]`
- Audit codebase for architecture / refactoring opportunities:
  `[[improve-codebase-architecture]]`
- Compact current conversation into a handoff document: `[[handoff]]`
- Author a new skill (skill scaffolding + progressive disclosure):
  `[[writing-great-skills]]`
- Skill layout: repo-owned skills tracked under `.agents/skills/<name>/`
  + `.claude/skills/` symlink; third-party (`mattpocock/skills`)
  machine-local, reinstall `npx skills@latest add mattpocock/skills`
  (ADR-00000011)
- Memory portability across machines: `.claude/scripts/setup-memory-link.sh`
