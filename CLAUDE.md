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

- Traditional Chinese README: **`README.zh-TW.md`** (hyphen, not
  underscore)
- English README: `README.md`
- Env template: `.env.example` (contains only `IMAGE_NAME=<name>`)
- Docker Compose: `compose.yaml` (not `docker-compose.yaml`)

## 目錄結構

See [CONTEXT.md §2.1](CONTEXT.md) for the full directory tree
(`docker/` top-level + `.claude/` internals). The
`check-claude-md-tree.sh` lint diffs that listing against the
filesystem.

## 常用指令

Container ops (downstream repos + base; wrappers under
`.base/script/docker/`):

```bash
make build           # build devel image  (e.g. make build test  |  make build -- --no-cache)
make run             # interactive run    (e.g. make run -- -d)
make exec            # exec into container (e.g. make exec -- -t bats-src bash)
make stop            # stop + remove containers
make setup           # regenerate .env + compose.yaml from setup.conf
make upgrade         # upgrade .base/ subtree (e.g. make upgrade v0.30.0)
```

Base self-test (template / docker_harness CI gate):

```bash
just ci test          # bats + shellcheck + kcov
just ci lint          # shellcheck only
just ci upgrade       # subtree pull to latest tag
```

For flags and overrides, read `<cmd> -h` or `make help` first.

## 標準容器結構

See [CONTEXT.md §2.2](CONTEXT.md) for the per-repo file layout
(Dockerfile / compose.yaml / wrapper symlinks / `.base/` subtree /
`doc/` / `test/smoke/` / etc.).

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
- Rebase a stale PR (BEHIND / CONFLICTING): `[[rebase-pr]]`
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
- Stress-test plan / design before commit: `[[grill-me]]` (Q&A) or
  `[[grill-with-docs]]` (Q&A that also updates CONTEXT.md / ADR
  inline as decisions crystallise)
- Break a plan / PRD into independently-grabbable issues: `[[to-issues]]`
- Diagnose hard bugs / performance regressions (reproduce → minimise
  → instrument → fix → regression-test): `[[diagnose]]`
- Throwaway prototype to flesh out a design before committing:
  `[[prototype]]`
- Audit codebase for architecture / refactoring opportunities:
  `[[improve-codebase-architecture]]`
- Re-perspective on a stuck big design: `[[zoom-out]]`
- Compact current conversation into a handoff document: `[[handoff]]`
- Author a new skill (skill scaffolding + progressive disclosure):
  `[[write-a-skill]]`
- Caveman mode (low-token communication): `[[caveman]]`
- Skill layout: repo-owned skills tracked under `.agents/skills/<name>/`
  + `.claude/skills/` symlink; third-party (`mattpocock/skills`)
  machine-local, reinstall `npx skills@latest add mattpocock/skills`
  (ADR-00000011)
- Memory portability across machines: `.claude/scripts/setup-memory-link.sh`
