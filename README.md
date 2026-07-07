# docker_harness

[![CI](https://github.com/ycpss91255-docker/docker_harness/actions/workflows/test.yaml/badge.svg)](https://github.com/ycpss91255-docker/docker_harness/actions/workflows/test.yaml) [![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](./LICENSE)

Workspace-level Claude Code configuration that applies across the
sub-repos checked out under this directory (template, agent/*, env/*,
app/*, multi_run, etc.). Tracks:

- `CLAUDE.md` — workspace-wide rules and project layout.
- `.claude/hooks/` — 10 PreToolUse / PostToolUse hooks enforcing those
  rules (no emoji, no AI attribution, no coverage excl, CHANGELOG /
  TEST.md drift, TDD reminders, docker-for-lint, subtree init,
  PR-wait-CI).
- `.claude/commands/` — slash commands (`/audit /batch-pr /doc-sync
  /new-repo /pr /release /safe-delete`).
- `.claude/skills/` — repo-owned skills (symlinks into
  `.agents/skills/`). Third-party skills are machine-local; see
  [Agent skills](#agent-skills).

Sub-repos in this workspace are managed independently and excluded via
`.gitignore`.

## Quick start

Open Claude Code at the workspace root so the hooks and slash commands
load:

```bash
cd /path/to/your/workspace
claude
```

Hook configuration lives in `.claude/settings.json`. Personal
permissions go in `.claude/settings.local.json` (gitignored).

## Agent skills

Skills live canonically under `.agents/skills/<name>/`, surfaced to
Claude Code as symlinks at `.claude/skills/<name>`.

- **Repo-owned skills** (this repo's own — `gh-artifact-format`,
  `semver-bump`, `wait-pr-ci`, `rebase-pr`, `wait-gh-state`,
  `strategic-compact`, `proactive-optimization`,
  `skillification-candidates`, `parallel-agents`, `batch-mutation-pr`)
  are tracked in git at both ends, so they are present on a fresh clone.
- **Third-party skills** (vendored from
  [`mattpocock/skills`](https://github.com/mattpocock/skills) — `tdd`,
  `grill-me`, `diagnose`, `handoff`, `prototype`, `to-issues`,
  `zoom-out`, `caveman`, `grill-with-docs`, `write-a-skill`,
  `improve-codebase-architecture`) are **machine-local and not tracked
  in git**. A fresh clone does not have them; install or refresh them
  with:

  ```bash
  npx skills@latest add mattpocock/skills
  ```

  Until installed, the corresponding workflows (e.g. `/tdd`,
  `/grill-me`) are unavailable. See
  [ADR-00000011](doc/adr/00000011-split-skill-tracking.md) for the
  rationale.

## Testing

All validation runs inside Docker so behaviour matches CI exactly
(CLAUDE.md「驗證一律走 Docker」). Test infra lives under `.claude/test/`
— invoke locally via `just -f .claude/test/justfile <target>` (CI
(`.github/workflows/test.yaml`) calls the same `.claude/test/ci.sh
<target>` driver directly):

```bash
just -f .claude/test/justfile build       # build the test image (docker_harness-test:local)
just -f .claude/test/justfile test        # run all bats specs
just -f .claude/test/justfile lint        # shellcheck on all hook + helper scripts
just -f .claude/test/justfile hadolint    # hadolint on .claude/test/Dockerfile
just -f .claude/test/justfile check       # lint + hadolint + test (full CI gate)
```

See [`doc/test/TEST.md`](doc/test/TEST.md) for the test catalog and
[`doc/changelog/CHANGELOG.md`](doc/changelog/CHANGELOG.md) for release
notes.

## Layout

```
docker/                       # workspace root
├── CLAUDE.md                 # workspace rules
├── README.md                 # this file
├── .github/workflows/        # docker_harness CI
├── .claude/
│   ├── settings.json         # hook + tool registration
│   ├── hooks/                # *.sh hook scripts + test/ specs
│   ├── commands/             # slash commands
│   ├── skills/               # symlinks into .agents/skills/ (repo-owned tracked)
│   └── test/                 # Dockerfile + Makefile for hook test image
├── doc/
│   ├── test/TEST.md          # test single source of truth
│   └── changelog/CHANGELOG.md
├── agent/  app/  env/        # sub-repos (independent)
├── template/  multi_run/     # sub-repos (independent)
└── org-profile/              # local checkout of ycpss91255-docker/.github
```

## License

Internal tooling. No external license; treat as part of the
ycpss91255-docker organisation.
