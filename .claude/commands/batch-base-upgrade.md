Batch-upgrade all downstream repos under `ycpss91255-docker` to a target `base` tag.

**Naming**: this slash command (and the underlying script) keeps the `template` prefix for backward compatibility with existing scripts / muscle memory. The upstream repo was renamed `ycpss91255-docker/template` -> `ycpss91255-docker/base` and the subtree prefix moved from `template/` -> `.base/`; the slash command keeps its old name so existing workflows do not break.

**Scope: workspace cwd only.** The implementation script (`.claude/scripts/batch-base-upgrade.sh`) iterates `<workspace>/<category>/<repo>/` directories that exist as siblings of `.base/` in the docker workspace. If running from a per-repo session, refuse and instruct the user to re-open Claude from the docker workspace root.

Use this **after** a new `base` tag has been pushed and the tag's CI is green. This propagates the new base version to all 13 downstream repos (agent / app / env) by opening one PR per repo.

## When to invoke

- A new `base` tag (`vX.Y.Z` or `vX.Y.Z-rcN`) just landed and you want downstreams on it.
- Re-running for repos that failed the previous batch (use `--only`).
- Dry-run inspection before committing to a real run.

## Why a dedicated command (vs `/batch-pr`)

`/batch-pr` is generic — it doesn't know `.base/` subtree mechanics:
- `./.base/upgrade.sh <tag>` runs subtree pull + integrity check + `init.sh` + `main.yaml` `@tag` rewrite
- `./.base/init.sh` re-runs after subtree pull to resync root symlinks
- Default branch is `main` for all 13 repos, but origin tracking can be stale (uses HTTPS fetch to bypass)

`/release` only covers the upstream tag flow; this is the consumer-side adoption.

## How it runs

The command delegates to `.claude/scripts/batch-base-upgrade.sh`. Designed to run from the **main session** — subagent sandbox blocks `git push`.

### Required arguments

- `<version>` — target tag (e.g. `v0.12.1`)
- One of:
  - `--why-file <path>` — markdown file with PR body Why-section content
  - `--why "<text>"` — inline alternative

### Optional flags

- `--issue <num>` — adds `Closes part of ycpss91255-docker/base#<num>.` to PR body
- `--dry-run` — print plan, no mutation
- `--only <r1,r2,...>` — limit to listed repos (relative paths, e.g. `agent/ai_agent`)
- `--skip <r1,r2,...>` — exclude listed repos (e.g. ones pinned to older tags)
- `--continue-on-error` — keep going past failed repos; print summary

### Examples

Dry-run preview:
```bash
.claude/scripts/batch-base-upgrade.sh v0.12.1 \
  --why-file /tmp/v0.12.1-why.md \
  --issue 151 \
  --dry-run
```

Real run, skipping pinned repos:
```bash
.claude/scripts/batch-base-upgrade.sh v0.12.1 \
  --why-file /tmp/v0.12.1-why.md \
  --issue 151 \
  --skip app/ros1_bridge,env/ros2_distro \
  --continue-on-error
```

Re-run for one failed repo:
```bash
.claude/scripts/batch-base-upgrade.sh v0.12.1 \
  --why-file /tmp/v0.12.1-why.md \
  --only env/ros_distro
```

## After the script

The script self-prints a copy-pasteable next-step block at end of run, with the exact `<reponame>:<pr_num>` pairs filled in:

```
next: wait CI then merge:
  .claude/scripts/wait-pr-ci-batch.sh ai_agent:194 claude_code:195 ... \
    --check-filter '.name=="call-docker-build / docker-build"'
  .claude/scripts/batch-pr-merge.sh ai_agent:194 claude_code:195 ...
```

Wrap the first line in a Monitor (so it doesn't block the agent on a long poll) and run the second after `ALL_DONE`. Detail below.

1. Wait for all 13 (or N) PRs' CI to settle in one Monitor stream. Use `wait-pr-ci-batch.sh`:
   ```
   Monitor(
     description: "batch v<X> CI",
     command: ".claude/scripts/wait-pr-ci-batch.sh ai_agent:<pr> claude_code:<pr> ... --check-filter '.name==\"call-docker-build / docker-build\"'",
     timeout_ms: 2400000,
     persistent: false,
   )
   ```
   (Container repos all use `call-docker-build / docker-build` as the only required check.) See `.claude/skills/wait-pr-ci/SKILL.md` for the full reference.
2. After `ALL_DONE`, batch-merge with `.claude/scripts/batch-pr-merge.sh`:
   ```bash
   .claude/scripts/batch-pr-merge.sh ai_agent:<pr> claude_code:<pr> ... | tail -30
   ```
   Short repo form is auto-prefixed with `ycpss91255-docker/`. Don't use an ad-hoc per-repo `for` loop — that's exactly the pattern the CLAUDE.md cross-repo batch-mutation rule rules out (one prompt per loop iteration -> yes-fatigue -> effectively bypasses the ask gate).
3. Verify each downstream main is now at the target tag with `.claude/scripts/check-template-versions.sh --expect v<X>`.

## Repo list

Hardcoded in the script (`DEFAULT_REPOS`). Currently 13 repos:

- `agent/{ai_agent,claude_code,codex_cli,gemini_cli}` (4)
- `app/{realsense_ros2,realsense_ros1,ros1_bridge,sick_humble,sick_noetic,urg_node_humble,urg_node_noetic}` (7)
- `env/{ros_distro,ros2_distro}` (2)

The 6 legacy single-distro env repos (`ros_noetic`, `ros_kinetic`,
`ros2_humble`, `osrf_ros_noetic`, `osrf_ros_kinetic`, `osrf_ros2_humble`)
were superseded by `ros_distro` / `ros2_distro` (single Dockerfile +
`BASE_IMAGE` ARG covers all variants) and archived on 2026-05-07. They
live locally under `archive/` for reference.

When new repos are added to the org, update the array.

Context from user: $ARGUMENTS
