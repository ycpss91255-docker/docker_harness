# Changelog

All notable changes to docker_harness are documented here. This file
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`remind_monitor_on_git_push.sh` completes the CI-watch umbrella
  (closes #157).** A `git push` that re-pushes / force-pushes an
  existing PR branch re-runs CI on the new head, but no `gh pr create`
  event fires to re-trigger `remind_pr_wait_ci`. This new PreToolUse
  Bash reminder fills that gap: it fires on `git push` (including
  `--force` / `--force-with-lease` / `git -C <dir> push` / explicit
  `git push origin <branch>`) when the command does NOT carry
  `-u` / `--set-upstream`, does NOT target `main`, and is NOT a tag
  push -- nudging to re-invoke `/wait-pr-ci` on the same PR. Initial
  `-u` pushes stay silent (the following `gh pr create` reminder
  covers them); main / tag pushes stay silent (no PR CI / owned by
  `enforce_semver_tag_via_script`). With this, all three
  CI-triggering surfaces are covered: `gh pr create`
  (`remind_pr_wait_ci`), `gh run rerun` / `gh workflow run`
  (`remind_monitor_on_ci_trigger`, #154), and `git push` (this, #157).
  11 new spec cases.
- **`enforce_gh_body_file.sh` enforces a decision record on issue
  close (closes #196).** Two new checks make the decision/resolution
  of a closed issue discoverable without spelunking. **Check A**: a
  `gh pr create` whose `--body-file` closes an issue
  (`closes`/`fixes`/`resolves #N`) is denied unless the body carries
  a `## Resolution` or `## Decision` heading -- the PR body is the
  canonical record. **Check B**: a manual `gh issue close N` is denied
  unless the issue already has a comment carrying that marker
  (queried via `gh issue view`); PR-merge auto-close is unaffected
  since it does not run `gh issue close`. Both checks fail open if the
  body-file is unreadable / gh is unreachable, so transient issues
  never block work. Future-only (existing closed issues are not
  backfilled -- their PR bodies already hold the decisions). 10 new
  spec cases; `gh-artifact-format` SKILL.md documents the rule and the
  Trivial-tier consequence (short closes now need a structured
  `--body-file`, not inline `--body`).
- **Vendor-in 11 Matt Pocock skills (closes #185).** `.agents/skills/`
  + `skills-lock.json` + 11 `.claude/skills/<name>` symlinks are now
  tracked in git, so fresh clones receive the full skill set without
  running an installer. Adopted: `caveman`, `diagnose`, `grill-me`,
  `grill-with-docs`, `handoff`, `improve-codebase-architecture`,
  `prototype`, `tdd`, `to-issues`, `write-a-skill`, `zoom-out`.
  Three Matt-Pocock-specific skills (`to-prd`, `triage`,
  `setup-matt-pocock-skills`) were excluded because they hard-depend
  on a 5-role triage label vocabulary this repo does not use.
  `to-issues/SKILL.md` has one line removed
  (the dangling `setup-matt-pocock-skills` reference); its lock
  `computedHash` is recomputed. CLAUDE.md Workflows table extended
  with 9 new rows (`tdd` was already listed) and a footnote naming
  `skills-lock.json` + `.agents/skills/` as the source of truth.
  Full decision recorded in ADR-00000010.
- **`enforce_semver_tag_via_script.sh` blocks `gh release create v*`
  (closes #181).** Before this PR, the boundary guard only matched
  `git tag v*` / `git push <v-tag>` / `git push --tags`. `gh release
  create v1.0.0` (which builds the tag server-side) bypassed every
  `.version` / RC / X-bump ACK check inside `release-tag.sh`. The
  hook now denies the gh path too, while `gh release list / view /
  edit / delete` and non-version tags (`release-2026`) still pass
  through. Spec adds 8 cases (3 deny + 5 silent) under
  `enforce_semver_tag_via_script_spec.bats`.
- **Forensic + auto-clean hooks for the worktree leak (closes #167).**
  Two new hooks observe and recover from the still-unidentified leak
  where files modified inside a `worktree/` branch surface as `M`
  entries in the main checkout (blocking `git pull --ff-only` until
  manually `git checkout HEAD --`'d).
  - `forensic_worktree_leak.sh` (Stop hook): scans the main checkout
    every turn for tracked-modified files outside the whitelist
    (`.claude/instincts.yaml` + `.claude/memory/**`) and appends a
    JSON line to `~/.claude/log/worktree-leak-events.jsonl` with
    `event:"detected"`, the `main_head` SHA, and per-file
    diff_head (first 30 lines). Throttled to 5 entries per session
    via `$TMPDIR` marker so noisy leaks do not flood the log.
  - `auto_clean_worktree_leak.sh` (PreToolUse Bash): fires on
    `git pull *`, `git checkout origin/*`, `git merge origin/*`,
    detects the same leak, appends a `cleaned` event to the same
    log, and runs `git checkout HEAD -- <files>` to restore tracked
    content before the sync command runs. The user no longer has to
    remember the manual recipe.
  Phase 2 (root-cause hunt) reads the accumulated log; design issue
  to follow once N>=5 anomalous events have been classified.

### Changed
- **Extracted `write_bats_stanzas` test helper (closes #166).** The
  `@test`-stanza-writing loop that two fixture factories
  (`mktemp_test_md_repo`, `mktemp_base_drift_repo`) hand-rolled is
  now a single `write_bats_stanzas <file> <count>` helper in
  `test_helper.bash`, carrying a one-paragraph comment documenting
  the bats preprocessor heredoc trap (literal `@test` at column 0
  inside a `<<'EOF'` heredoc is rewritten before bash sees it,
  silently truncating the fixture -- the trap that produced
  `((: 0 0: syntax error` in #156). 2 new helper smoke tests added.
  TEST.md total also reconciled 899 -> 911 (the 908 smoke + 3
  integration reflects actual `@test` counts; the prior 899 had
  drifted ~10 below reality across intervening PRs).
- **Trimmed 4 native SKILL.md `description:` fields under ~250 chars
  (closes #173).** A skill manifest's `description` ships in the
  system prompt every turn, so verbose descriptions are a recurring
  token tax. Trimmed `skillification-candidates` (339->244),
  `proactive-optimization` (320->239), `parallel-agents` (299->232),
  `gh-artifact-format` (297->248) while preserving the
  what-it-does + when-to-use shape. Vendored skills (from
  `mattpocock/skills`) were intentionally left untouched to stay 1:1
  with upstream and avoid `skills-lock.json` `computedHash` drift;
  `prototype` (426, the remaining outlier) is upstream's and would
  need a separate per-install override mechanism, tracked separately.
  Empty descriptions (`rebase-pr` / `semver-bump`) and the worst
  offender (`setup-matt-pocock-skills`, 438) were already handled by
  #178 and #185.
- **`/new-repo` rewritten to a template-based 4-step flow
  (closes #151).** The old 10-step manual workflow (manual
  `git subtree add`, hardwired `ln -sf .base/build.sh` symlinks,
  `make upgrade` refs, env/agent/app repo-type classification) is
  replaced by: `gh repo create --template ycpss91255-docker/template`
  -> `./bootstrap.sh [<base-tag>]` (the template's self-deleting
  script re-establishes the `.base/` subtree history a Template
  clone cannot carry, runs `init.sh`, then removes itself) ->
  post-setup (topics.yaml / branch protection / org profile README)
  -> `just build test`. The env/agent/app distinction is dropped
  (all downstream repos share one architecture). The
  `ycpss91255-docker/template` GitHub Template repo + its
  `bootstrap.sh` already exist; this change is the docker_harness-side
  skill rewrite only.

### Removed
- **`remind_subtree_init.sh` deleted as redundant (closes #182).** The
  reminder fired on `git subtree pull --prefix=.base/template`, but
  that exact surface is already DENIED upstream by
  `enforce_make_first_upgrade.sh` (PreToolUse Bash deny + checkpoint
  ack). By the time the reminder fired the user had explicitly ack'd
  the deny, so the nudge was always too late to redirect behaviour.
  Hook + smoke spec removed; `chain_spec.bats` integration row
  dropped; `settings.json` wiring removed; CONTEXT.md tree synced;
  TEST.md totals 887 -> 882 (879 smoke + 3 integration).

### Added
- **`wait-pr-ci` family emits JSON event log on every terminal exit
  (refs #175 Phase 1).** `wait-pr-ci.sh`, `wait-pr-ci-batch.sh`, and
  `wait-tag-ci.sh` now append one JSON object per invocation to
  `~/.claude/log/wait-pr-ci-events.log` with `ts` / `script` /
  `exit_reason` (`ALL_DONE` / `FAIL` / `timeout_max_iter`) /
  `iterations` / `elapsed_sec`, plus per-script identity (`repo` +
  `prs[]` for single, `pairs[]` for batch, `branch` for tag).
  Non-fatal: emit is wrapped so EACCES / EISDIR / ENOSPC never blocks
  the script's primary work. Phase 2 reads this log to classify
  "Monitor stuck" failure modes -- watchdog design is parked until
  N>=10 anomalous events accumulate. Schema and disable / inspect
  recipes documented in `.claude/skills/wait-pr-ci/SKILL.md`.

### Fixed
- **`remind_strategic_compact.sh` re-baselines counters at the last
  `/compact` (closes #170).** Pre-fix the Stop hook summed
  `tool_count` / `pr_merge_count` across the whole transcript jsonl
  and re-fired every time the throttle hash crossed a new
  `tool_count / 25` bucket -- even after the user had already run
  `/compact`, because counters only grew. Now the hook finds the
  last `type=system && subtype=compact_boundary` entry in the
  transcript (the marker Claude Code emits per `/compact`, manual
  or auto) and slices the count to only entries after it; sessions
  without a compact fall back to whole-session counting
  (backwards-compatible). Both `tool_count` and `pr_merge_count`
  re-baseline symmetrically -- a PR merged before `/compact` no
  longer shows up in the reason list. Throttle hash formula
  unchanged.

### Changed
- **`remind_strategic_compact.sh` `DEFAULT_TOOL_THRESHOLD` raised
  50 -> 100 (refs #170).** 50 was conservative for active sessions
  (5+ tools per turn is normal); combined with the pre-#170 re-fire
  bug it surfaced the reminder uncomfortably often. 100 is the new
  sweet spot for "you have done enough turn-by-turn work that
  compaction would reduce load". Override via
  `STRATEGIC_COMPACT_TOOL_THRESHOLD=<N>` per session unchanged.
  `.claude/skills/strategic-compact/SKILL.md` text `Session has
  done >50 tool calls without /compact` -> `>100 tool calls since
  the last /compact` to match.
- **`sync-org-repo-settings.sh` scope narrowed to base-aligned
  repos.** `ALL_REPOS` no longer enumerates the full org -- it
  lists only the 23 repos that follow the base workflow (base +
  `.base/` subtree consumers + adjacent tooling: `multi_run`,
  `docker_harness`, `template`, `.github`). One-off projects
  with distinct conventions stay out: `github_runner`
  (self-hosted runner provisioning per ADR-0012) and
  `demo-repository` (deleted upstream). The script preamble +
  inline comment over `ALL_REPOS` document the inclusion rule
  so future readers don't widen scope by default. Smoke spec
  adds an explicit exclusion check.

### Added
- **`sync-org-repo-settings.sh` for idempotent org-wide repo
  settings alignment.** Single source of truth for the 23
  base-aligned repos in the `ycpss91255-docker` org: fork PR
  approval =
  `all_external_contributors`, repo-level merge defaults
  (`allow_auto_merge` / `delete_branch_on_merge` /
  `allow_update_branch` = true; `allow_merge_commit` = false so
  the UI merge dropdown defaults to squash), and branch
  protection on `main` with per-repo `required_status_checks`
  drawn from the same mapping used by `wait-pr-ci.sh` (base =
  `ci-rollup`, single-target containers =
  `call-docker-build / docker-build`, etc). `--dry-run` previews
  deltas; each PUT / PATCH only fires when current state !=
  target. Private repos (`demo-repository`) auto-skip
  `fork-pr-contributor-approval` (API 422 "not allowed for
  private repos") and branch protection (free-tier 403 "Upgrade
  to Pro") -- detected via `repo.private`, not a hardcoded
  list. `.github` keeps protection on but with no required
  check because doc-only PRs bypass `lint` entirely and would
  otherwise hang `wait-pr-ci` forever. Smoke bats spec covers
  `--help`, `unrecognised_arg`, and the `required_check_for`
  mapping table.

### Changed
- **`check_test_md_drift.sh` now also tracks
  `.base/test/smoke/*.bats` headings (closes #156).** The TEST.md
  heading regex extended from `### test/<path>.bats (N)` to
  `### (\.base/)?test/<path>.bats (N)`. Downstream repos that
  vendor shared template tests via the `.base/` subtree (e.g.
  `.base/test/smoke/script_help.bats`) can now pin counts on
  those files; previously a base subtree pull that landed new
  `@test` stanzas would drift TEST.md silently because the regex
  required the heading to start with `test/`, missing the
  `.base/` prefix entirely. Repo discovery (walk up to find
  `test/` + `doc/test/TEST.md`) is unchanged and already worked
  when the touched bats file lives under `.base/`.
- **Rename `.github/workflows/test.yaml` `name:` from `test` to
  `CI` (closes #155).** Matches the README badge label `CI` and
  the org-wide convention. File path stays `test.yaml`, so the
  README badge URL (`actions/workflows/test.yaml/badge.svg`) is
  unchanged. Job name `bats + shellcheck + hadolint` stays
  unchanged so the per-PR required check name is unaffected.

### Added
- **PreToolUse hook `remind_monitor_on_ci_trigger.sh` covering
  `gh workflow run` + `gh run rerun` (closes #154).** Sibling of
  `remind_pr_wait_ci.sh` (which only fires on `gh pr create`).
  Without this hook the agent could trigger a manual
  workflow_dispatch or re-run a failed run and then forget to arm
  a Monitor, leaving CI results unchecked or sleep-polled.
  - `gh workflow run ...` (workflow_dispatch) is always
    tag/branch-scoped → message points at `wait-tag-ci.sh`.
  - `gh run rerun ...` can be either PR-scoped or
    tag/branch-scoped → message mentions both `/wait-pr-ci` skill
    and `wait-tag-ci.sh` so the agent picks based on context.
  - Non-blocking (always exit 0); registered in
    `.claude/settings.json` `PreToolUse > Bash` block alongside
    `remind_pr_wait_ci.sh`. 13 smoke cases under
    `.claude/hooks/test/smoke/remind_monitor_on_ci_trigger_spec.bats`
    (cover both fire paths, chained commands, and silent paths for
    `gh run list` / `gh run view` / `gh run watch` /
    `gh workflow list` / `gh workflow view`).
- **CI lint + PostToolUse hook + instinct entry enforcing
  `lib/log.sh` adoption (closes #148, M5 of 5).** Final phase of
  the five-PR `#148` plan that started in #158.
  - `.claude/scripts/check-log-helper-usage.sh` -- scans
    `.claude/scripts/*.sh` (excluding `lib/`) for bare `printf` /
    `echo` callsites outside `usage()` bodies. Three allowlist
    layers: `# log-allow:script` at file top (file-wide skip),
    `# log-allow:start` ... `# log-allow:end` block markers, and
    automatic skip inside `usage()` function bodies (heredoc /
    sed-extracted help text). Reports `file:line: bare <op>` on
    stderr plus a final tally; exits 1 on any violation, 0 on
    clean, 2 on arg error. Wired into the CI gate via the new
    `log-helper-check` target in `.claude/test/Makefile`; the
    `check` aggregator now includes it.
  - `.claude/hooks/remind_log_helper.sh` -- PostToolUse hook
    (Edit / Write / MultiEdit). On touches to
    `.claude/scripts/*.sh` (excluding `lib/`), delegates to the
    lint scoped to the single touched file and surfaces any bare
    `printf` / `echo` as a non-blocking `systemMessage` nudge
    with the canonical `_log_<level> <service> <body>
    [attr=val]...` shape. Wired into `.claude/settings.json`
    PostToolUse alongside the other Edit/Write hooks.
  - `.claude/instincts.yaml` -- new `bash-log-via-lib` instinct
    (kind `file_edit`, glob `.claude/scripts/**/*.sh`, not_glob
    `lib/**`). Documents the 5-level vocabulary
    (`_log_debug` / `_log_info` / `_log_warn` / `_log_err` /
    `_log_fatal`), strict body-enum (`lib/log-events.txt`),
    tty-detect dispatch, and allowlist markers.
  - Allowlist markers applied to every existing
    `.claude/scripts/*.sh` (excluding `lib/`) so the lint passes
    against the current tree as a baseline. Each marker is a
    `# log-allow:script` comment with rationale ("emits
    data-product output (markdown table / next-step hint /
    Monitor protocol / pass-fail summary) alongside `_log_*`").
    Future per-callsite splits can replace the file-wide marker
    with block-level markers once tooling can reliably
    distinguish data-product printf from log-event printf.
  - Bats specs: `check_log_helper_usage_spec.bats` (13 cases) +
    `remind_log_helper_spec.bats` (7 cases).
  - This phase wraps the `#148` umbrella: the lint, hook, and
    instinct together codify the "diagnostics go through
    `lib/log.sh`" rule that M1-M4 progressively migrated callers
    toward.

### Changed
- **Migrate wait-\* family to lib/log.sh (refs #148, M4 of 5).**
  Replaced bare `printf '[wait-X] ERROR: ...'` arg-parse / max-iter
  diagnostics with structured `_log_fatal precondition_missing` /
  `_log_fatal unrecognised_arg` / `_log_err wait_failed
  reason=max-iterations` callsites in `wait-pr-ci.sh`,
  `wait-pr-ci-batch.sh`, `wait-tag-ci.sh`, `wait-issue-close.sh`,
  and `wait-release.sh`. Removed each script's local `err()`
  helper. The wait scripts' main protocol output (per-PR
  `PR<n>: checks=<state> mergeable=<m>` snapshots, `ALL_DONE` /
  `FAIL <pr>` final lines, `[head-moved] PR<n> <old7>..<new7>`
  markers) deliberately stayed as `printf` -- those are the
  script's documented Monitor-consumed protocol, not log events;
  migrating would break the wait-pr-ci skill's poll-and-parse
  contract. Sourced `lib/log.sh` into `rebase-pr.sh` for future
  callsite migration (no functional change in this PR). Updated
  `wait_pr_ci_spec.bats`, `wait_pr_ci_batch_spec.bats`,
  `wait_tag_ci_spec.bats`, `wait_issue_close_spec.bats`, and
  `wait_release_spec.bats` arg-parse-error assertions to match
  the JSON output. The remaining M4-survey utility scripts
  (`instinct-query.sh`, `release-tag.sh`, `new-adr.sh`,
  `setup-memory-link.sh`, `run-bats-in-compose.sh`,
  `migrate-local-to-setupconf.sh`, `check-claude-md-ceiling.sh`,
  `check-claude-md-tree.sh`, `check-template-versions.sh`) keep
  their existing diagnostic `printf` / `echo` because each has
  user-facing data-product output (markdown summary, table rows,
  pass/fail status) that the bats specs assert on by exact text;
  per-callsite migration deferred until M5 introduces the lint
  allowlist pragma for marked data-product blocks.
- **Migrate batch-\* + fix-\* remainder to lib/log.sh (refs #148, M3
  of 5).** Replaced bare `printf` / `echo` diagnostics with `_log_*`
  callsites in `batch-pr-merge.sh`, `batch-pr-close.sh`,
  `batch-gitignore-add-line.sh`, `batch-gitignore-fix.sh`,
  `batch-rename-template-to-base.sh`, `batch-sensor-app-v0.27.sh`,
  `batch-open-archive-rename-issues.sh`, `fix-compose-copy-line.sh`,
  `fix-dockerfile-lint-lib.sh`, and `fix-dockerfile-copy-script.sh`.
  Removed redundant local `err()` / `info()` helpers in favour of
  inline `_log_*` calls with structured `repo=` / `pr=` / `reason=`
  attributes. `print_next_step_hint` blocks, `opened:` /
  `skipped:` / `failed:` per-item lists, and PR body file content
  stayed as `printf` -- those are data products. Added
  `patch_applied` / `patch_skipped` / `patch_failed` / `pr_failed`
  / `issue_created` / `issue_skipped` / `issue_failed` to
  `log-events.txt` for the new event categories. Updated
  `batch_gitignore_add_line_spec.bats`,
  `batch_gitignore_fix_spec.bats`,
  `batch_open_archive_rename_issues_spec.bats`,
  `batch_pr_close_spec.bats`, `batch_pr_merge_spec.bats`, and
  `fix_dockerfile_lint_lib_spec.bats` assertions to match JSON
  output emitted in non-tty test capture.
- **Migrate top-4 callers to lib/log.sh (refs #148, M2 of 5).**
  Replaced bare `printf` / `echo` diagnostics with `_log_*`
  callsites in `verify.sh` (drift / lint / arg errors),
  `batch-base-upgrade.sh` (summary + per-repo events,
  removed `err`/`info` helpers), `ci-wall-time-compare.sh`
  (gh API failures + precondition errors), and
  `batch-license-apache.sh` (processing / skip / license
  source). Markdown report output (verify summary table,
  ci-wall-time-compare table, batch-base-upgrade
  `print_next_step_hint`, dry-run plans) stays as `printf`
  -- those are data products, not log events. Added
  `api_error` to `log-events.txt` for the gh CLI failure
  path. Updated `verify_spec.bats`,
  `batch_base_upgrade_spec.bats`, and
  `ci_wall_time_compare_spec.bats` assertions to match the
  JSON output emitted in non-tty test capture. M3-M5
  follow up to migrate the remaining batch / fix / wait
  families and add CI lint enforcement.

### Added
- **OTel-aligned log.sh mirror lib (refs #148, M1 of 5).**
  Vendored `ycpss91255-docker/base@v0.37.0`'s
  `script/docker/lib/log.sh` into
  `.claude/scripts/lib/log.sh`. Sibling files
  (`log.lnav-format.json`) shipped verbatim;
  `log-events.txt` seeded with docker_harness-specific event
  vocabulary derived from the migration survey (batch ops,
  verify, wait-* family, error class). Header annotates the
  upstream source + sync-when-upstream-changes contract.
  Unit spec `.claude/hooks/test/smoke/log_spec.bats`
  (48 cases) covers 5-level helpers, tty-detect dispatch
  (text on TTY / JSON on pipe), `LOG_FORMAT` override,
  `_log_with_trace` / `_log_with_span` scoped wrappers,
  W3C TRACEPARENT parsing, strict body enforcement,
  microsecond UTC timestamp. No existing
  `.claude/scripts/*.sh` callsite migrates in this PR --
  vendoring + spec land first, M2-M5 follow-up PRs migrate
  callers + add CI lint. Refs
  `ycpss91255-docker/base#423` (umbrella contract spec) +
  `ycpss91255-docker/base#438` (dispatch refinement +
  microsecond + strict body default).

### Changed
- **Post-rename drift sweep (closes #150).** Stale references
  surfaced after #127 (CLAUDE.md slim moved the directory tree
  to CONTEXT.md sec 2.1), #130 (lifecycle annotations stripped
  from the same tree), and #146 (`/batch-template-upgrade`
  renamed to `/batch-base-upgrade` plus the script renamed
  accordingly):
  - `doc/adr/00000007-slash-command-first-over-ad-hoc.md` --
    three `/batch-template-upgrade` mentions updated to
    `/batch-base-upgrade`; the
    `.claude/commands/batch-template-upgrade.md` path reference
    updated to `.claude/commands/batch-base-upgrade.md`.
  - `.claude/scripts/batch-open-archive-rename-issues.sh:124`
    issue-body template -- the acceptance-checklist line that
    pointed at `CLAUDE.md` directory-tree retargeted to
    `CONTEXT.md sec 2.1` (post-#127 location). The line also
    notes that post-#130 per-repo lifecycle annotations live in
    `batch-base-upgrade.sh` `DEFAULT_REPOS` plus this script's
    follow-up issues, not in the tree listing itself.
  - `.claude/memory/feedback_template_subtree_upgrade.md`
    renamed to `feedback_base_subtree_upgrade.md` with content
    refreshed: `template/init.sh` -> `.base/init.sh`,
    `.template_version` -> `.base/.version`, and a note that
    `enforce_make_first_upgrade.sh` now BLOCKs raw subtree pull
    in favour of the make wrapper.
  - `.claude/memory/feedback_make_first_upgrade.md` refreshed
    so the canonical fallback reads `./.base/upgrade.sh`
    (legacy `./template/upgrade.sh` mentioned only as the
    old-folder-name variant the hook also catches); cross-link
    added to `[[feedback_base_subtree_upgrade]]`.
  - `.claude/memory/MEMORY.md` index entries for the two
    memory files updated to `.base subtree` titles + refreshed
    one-line hooks.

  Working-as-designed references that intentionally still
  mention the legacy names (`enforce_make_first_upgrade.sh`
  surface 2, `check_readme_framework.sh` `.template_version`
  catcher, `instincts.yaml:133` mirror,
  `feedback_subagent_sandbox_limits.md` incident narrative,
  historical CHANGELOG entries) are NOT touched -- see the
  #150 body for the full "do not change" list.

- **Workspace path portability across users / machines
  (closes #143).** Three places hard-coded
  `/home/yunchien/workspace/docker` as the workspace path:
  - `.claude/settings.json` sandbox `filesystem.allowWrite` only
    contained `/tmp`, so every `git worktree remove worktree/*`
    tripped "Read-only file system" and required per-call
    `dangerouslyDisableSandbox` (the precedent: `base#389 / #391 /
    #392` all hit this at cleanup). Added `"worktree"` as a
    relative entry (resolved against `${CLAUDE_PROJECT_DIR}`).
  - `.claude/scripts/batch-license-apache.sh` and
    `.claude/scripts/fix-compose-copy-line.sh` defaulted
    `WORKSPACE` to the hard-coded path when
    `${CLAUDE_PROJECT_DIR}` / `${WORKSPACE}` were unset. Both
    now derive from `BASH_SOURCE` (script lives at
    `.claude/scripts/<name>.sh`, so `../..` lands on the
    workspace root). Works in any clone location.
  - `.claude/hooks/test/smoke/auto_allow_rm_in_workspace_spec.bats`
    `setup()` exported a hard-coded `CLAUDE_PROJECT_DIR`; the
    "allows rm <absolute under workspace>" test case hard-coded
    the same path in the command body. Both now derive from
    `${BATS_TEST_DIRNAME}` so the spec passes wherever the
    workspace lives on disk. The "silent on /home/yunchien/.bashrc"
    test case stays as-is -- the literal path is just a
    representative "outside workspace" location, unchanged by
    workspace base derivation.

  Phase 1 (`settings.json`) ships an experimental relative
  `"worktree"` entry; sandbox interpolation semantics need
  empirical verification on next session reload. If bwrap takes
  the relative path raw (rather than resolving against
  `${CLAUDE_PROJECT_DIR}`) a follow-up will switch to absolute
  or `${HOME}` interpolation.

- **CONTEXT.md `### Directory tree` lifecycle annotations stripped
  (closes #130).** The docker/ subtree listing previously mixed
  filesystem facts with lifecycle decision state (per-repo
  `archive 待辦` / `rename -> <new>` / `template/->.base/ 待辦`
  annotations + group-header count summaries like
  `(3 個 archive 待辦 + 4 個 rename + .base 遷移待辦)`).
  `.claude/scripts/check-claude-md-tree.sh` validates paths only --
  not annotations -- so the lifecycle layer drifted silently
  (concrete precedent: `base#378` audit refuted the
  `app/ros1_bridge/` archive-pending annotation; the
  multi-distro dispatcher + from-source catkin builder is
  architecturally distinct from env/* and was kept active per
  `ros1_bridge#103`). Per-repo lifecycle state is now sourced
  exclusively from `.claude/scripts/batch-base-upgrade.sh`
  `DEFAULT_REPOS` (active vs comment-out) and the GitHub issues
  opened via
  `.claude/scripts/batch-open-archive-rename-issues.sh`. A pointer
  paragraph immediately under the heading documents the split.
  ros1_bridge entry replaced with a positive description
  ("ROS 1 <-> ROS 2 bridge (multi-distro dispatcher + from-source
  catkin builder)"). Issue #130 originally targeted CLAUDE.md;
  #127 (CLAUDE.md slim) migrated the listing to CONTEXT.md §2.1
  so the cleanup landed there with scope unchanged.

- **`/batch-template-upgrade` renamed to `/batch-base-upgrade`** (closes #146).
  The upstream repo + subtree prefix moved from `template/` to `base/` +
  `.base/` long ago; the legacy command name kept causing confusion
  (operates on `.base/`, not `template/`). Rename touches:
  - `.claude/commands/batch-template-upgrade.md` ->
    `.claude/commands/batch-base-upgrade.md`
  - `.claude/scripts/batch-template-upgrade.sh` ->
    `.claude/scripts/batch-base-upgrade.sh`
  - `.claude/scripts/batch-template-pr-body.template.md` ->
    `.claude/scripts/batch-base-pr-body.template.md`
  - Internal chore branch name `chore/template-vX.Y.Z` ->
    `chore/base-vX.Y.Z`
  - `permissions.allow` entry + every cross-reference (CLAUDE.md,
    hooks, sibling scripts, skill docs, instincts.yaml, smoke spec
    filename + content) sed-flipped to the new spelling.
- **`batch-pr-merge.sh` gains `--reset-local`** (closes #146). After
  each successful squash-merge, runs `git fetch + checkout main +
  reset --hard origin/main` against the repo's local checkout
  (resolved via the standard layout: `env/<repo>` / `app/<repo>` /
  `agent/<repo>` / `<repo>` at workspace root; `base` -> `template/`
  special case). Best-effort -- missing checkouts or git failures log
  + skip without failing the merge step. Closes the detached-HEAD
  aftermath of `batch-base-upgrade.sh`'s main-checkout flow that
  surfaced after the v0.34.0 fanout to `env/ros_distro#25` +
  `env/ros2_distro#24`. The `print_next_step_hint` block in
  `batch-base-upgrade.sh` now emits `batch-pr-merge.sh --reset-local`
  by default plus a rationale paragraph so the cleanup is on-by-default
  in the documented flow.
- **CLAUDE.md slim (closes #127, closes #116 umbrella)**: shrunk
  from ~965 lines / 20 top-level `##` (64 incl. `###`/`####`) to
  109 lines / 7 top-level `##`. Per the 64-section A / B / C / D /
  E1 / E2 / F disposition from #108 close comment:
  - **A (6)** style rules deleted -- hooks enforce
    (`check_no_emoji.sh` / `check_no_ai_attribution.sh` /
    `check_no_coverage_excl.sh`).
  - **B (13)** collapsed into a single `## Workflows` bullet list,
    each row pointing at the owning `[[skill]]` or `/cmd` (no
    orphan prose).
  - **C (28)** moved to `CONTEXT.md` -- most already landed in
    Sub#2 (#118); this PR adds the `.claude/` tree to
    `CONTEXT.md §2.1` and three new sections (`§14. Sandbox
    baseline`, `§15. Bash command shape -- parser limits`,
    `§16. Per-project memory`).
  - **D (4)** stay in `doc/adr/00000004..00000007.md` from Sub#3
    (#119); prose deleted from CLAUDE.md.
  - **E1 (3)** deleted -- `[[proactive-optimization]]` (#124 /
    #140), `[[skillification-candidates]]` (#125 / #141),
    `[[parallel-agents]]` (#126 / #142) skills + Stop /
    UserPromptSubmit hooks carry the rules.
  - **E2 (4)** deleted -- `enforce_make_first_upgrade.sh`
    (#120 / #139), `enforce_batch_via_script.sh` (#121),
    `enforce_worktree_for_branch.sh` (#122) hooks +
    `/tmp/claude-checkpoint-*` ACK protocol (ADR-00000002 /
    #117) carry the rules.
  - **F (6)** retained in CLAUDE.md: 專案概述 / 檔案命名慣例 /
    目錄結構 (pointer to CONTEXT.md §2.1) / 常用指令 (now
    make-first) / 標準容器結構 (pointer to CONTEXT.md §2.2) /
    Git 設定.
- `.claude/scripts/check-claude-md-tree.sh` docstring + `--help`
  reflect that the make target now passes `CONTEXT.md` (where the
  `.claude/` tree listing lives post-#127). Script logic
  unchanged; defaults to `CLAUDE.md` if invoked without arg.
- `.claude/test/Makefile`: `tree-check` target now invokes the
  script against `CONTEXT.md` instead of `CLAUDE.md`;
  `ceiling-check` target added and wired into the `check` chain
  so CLAUDE.md drift over 240 lines / 20 `^##` sections fails CI.

### Added
- `.claude/scripts/check-claude-md-ceiling.sh` -- CI lint that asserts
  a markdown file (default `CLAUDE.md`) stays under hard line and
  `^##` section ceilings (defaults `MAX_LINES=240` / `MAX_SECTIONS=20`,
  env-overridable). Exits 1 with `FAIL: ...` to stderr on violation,
  exits 0 with a one-line summary on pass, exits 2 when the file does
  not exist. Ships in #127 PR-A as the tool for the slim; PR-B wires
  it into `make -C .claude/test check` once the post-slim CLAUDE.md
  actually fits the ceilings. Splitting the tool from the gate avoids
  a CI-red window between landing the gate and complying with it
  (refs #127, Tier 4 of #116).
- `.claude/hooks/test/smoke/check_claude_md_ceiling_spec.bats` (7
  cases): `--help` exits 0 with usage; missing file exits 2; within
  default ceilings (240/20) exits 0; lines exceed default exits 1
  with `FAIL` message; sections exceed default exits 1; `MAX_LINES`
  env override (tighter) triggers FAIL; `MAX_SECTIONS` env override
  (tighter) triggers FAIL. TEST.md total 763 -> 770; helper-script
  shellcheck count 28 -> 29.

- `.claude/skills/parallel-agents/SKILL.md` +
  `.claude/hooks/remind_parallel_when_bulk.sh` -- skill +
  UserPromptSubmit hook pair giving the CLAUDE.md "Use parallel Agents
  for large workloads" rule an auto-invocation surface (refs #126,
  Tier 3 of #116, skill 3 of 3). The skill describes when to dispatch
  parallel Agents (N >= 4 independent items, no sequential dependency,
  no shared-state mutation), when NOT (small N, sequential, bespoke
  per-item, batch-script territory), the cap (max 3), how to dispatch
  (multiple Agent tool calls in one response), and the per-Agent
  prompt shape (target list / task / output shape / length cap).
  The UserPromptSubmit hook scans the prompt text for bulk indicators
  via three patterns: (A) numeric `N >= PARALLEL_REMIND_THRESHOLD`
  (default 4) followed by a plural noun from the bulk list (repos /
  PRs / pull requests / issues / files / workflows / tests / hooks /
  directories / branches / repositories); (B) `all`/`every`/`each` +
  plural noun, plus CJK quantifier variant (全部/所有/每個 + bulk
  noun); (C) explicit comma-separated list of >= threshold
  repo-shaped tokens. Suppressed when the prompt already mentions
  `parallel`, `concurrent`, `subagent`, `平行`, `並行`, `spawn agents`,
  or `dispatch agents`. Defensive false-positive guards: version-
  shaped numbers like `v0.32.0` and ordinal phrasing like `the 4th
  issue` do not match. Throttled via TMPDIR marker. Configurable via
  `PARALLEL_REMIND_DISABLE=1` and `PARALLEL_REMIND_THRESHOLD=<N>`.
  Introduces the first `UserPromptSubmit` chain in `.claude/settings.json`
  (previously only `PreToolUse`, `PostToolUse`, `Stop`). 18 new bats
  cases; TEST.md total 745 -> 763; shellcheck hook count 33 -> 34.
  CLAUDE.md tree listing + "工作量大時使用平行 Agent" prose section
  updated to point at the skill and hook.

- `.claude/skills/skillification-candidates/SKILL.md` +
  `.claude/hooks/remind_skillification_candidates.sh` -- skill + Stop
  hook pair giving the CLAUDE.md "End-of-task: list skillification
  candidates" rule an auto-invocation surface (refs #125, Tier 3 of
  #116, skill 2 of 3). The skill describes the four candidate
  categories with a "signal you saw it" column and an artifact-shape
  column: (1) `/tmp/*.sh` re-use -> permanent `.claude/scripts/<name>.sh`;
  (2) parser-fallback Bash repetition -> permanent script with atomic
  flags; (3) slash-command gap -> sketch new `.claude/commands/<name>.md`;
  (4) bug in existing skill -> one-line skill patch or follow-up issue.
  The Stop hook covers categories 1 and 2 (the auto-detectable signals)
  by scanning `transcript_path` JSONL for Bash invocations matching
  `/tmp/[^/]+\.sh` paths or parser-fallback patterns (heredoc redirect,
  `${var%suffix}` expansion, `<<<` herestring, `cd path && tool`,
  `(cd path && ...)` subshell). Fires when either count >= its
  threshold (defaults 3 each) AND the session has NOT already raised
  a skillification candidate via the regex (skill-ify / skillification
  / promote to .claude/scripts / new slash command / workflow gap;
  case-insensitive). Throttled via TMPDIR marker. Configurable via
  `SKILLIFICATION_REMIND_DISABLE=1`,
  `SKILLIFICATION_TMP_THRESHOLD=<N>`,
  `SKILLIFICATION_PARSER_THRESHOLD=<N>`. Categories 3 and 4 require
  semantic understanding the hook does not have; the skill body covers
  them so the agent surfaces them when it spots them. 16 new bats
  cases; TEST.md total 729 -> 745; shellcheck hook count 32 -> 33.
  CLAUDE.md tree listing + skillify prose section updated to point at
  the skill and hook.

- `.claude/skills/proactive-optimization/SKILL.md` +
  `.claude/hooks/remind_proactive_optimization.sh` -- skill + Stop hook
  pair giving the CLAUDE.md "## 主動優化建議" rule an auto-invocation
  surface (refs #124, Tier 3 of #116, skill 1 of 3). The skill describes
  the four optimisation-candidate categories (workflow ergonomics,
  cross-repo inconsistency, doc drift, manual repetition), the offer
  phrasing (one-paragraph question, not a unilateral fix), and the
  when-not-to-offer cases. The Stop hook fires once-per-session per
  signal-set when (a) a task boundary signal holds (`gh pr merge`
  invoked OR tool-call count >= `PROACTIVE_OPTIMIZATION_REMIND_THRESHOLD`,
  default 50) AND (b) the session has NOT already mentioned an
  optimisation candidate via the regex (optimisation / automate /
  scripted / DRY / redundant / skill candidate / skill-ify etc.,
  case-insensitive). Throttled via TMPDIR marker, configurable via
  `PROACTIVE_OPTIMIZATION_REMIND_DISABLE=1`. 13 new bats cases; TEST.md
  total 716 -> 729; shellcheck hook count 31 -> 32. CLAUDE.md tree
  listing + "## 主動優化建議" prose section updated to point at the
  skill and hook.

### Changed
- `.claude/hooks/enforce_make_first_upgrade.sh` -- scope expanded to
  cover three surfaces instead of one (#120 follow-up per the #123
  close-comment promise). New detection patterns:
  - `./template/upgrade.sh ...` (legacy local folder name; the GitHub
    repo was renamed `template -> base` but some checkouts retain the
    old folder layout).
  - `git subtree pull --prefix=.base ...` / `--prefix=template ...`
    (raw subtree pull -- skips the same init.sh + main.yaml @tag steps
    as the raw `.sh` form).
  All three surfaces share the same canonical (`make -f Makefile.ci
  upgrade VERSION=vX.Y.Z`), reason, checkpoint slug, and ack-bypass
  path. `git subtree push` and `git subtree pull --prefix=foo` (other
  prefixes) pass through silently. CLAUDE.md tree + hook supplement
  section + `.claude/instincts.yaml > make-first-upgrade` updated.
  TEST.md total 709 -> 716 (7 new bats cases across the two new
  surfaces and their discriminators); shellcheck hook count unchanged
  (no new files).

### Added
- `.claude/hooks/enforce_worktree_for_branch.sh` -- BLOCKING PreToolUse
  Bash hook (refs #122, Tier 2 of #116 hook 3 of 4). DENIES
  `git checkout -b|-B <branch>` invocations targeting the main checkout
  (where `git rev-parse --git-dir` equals `--git-common-dir`), routing
  the agent to `git worktree add <workspace>/worktree/<repo>-<N> -b
  <branch> main` so the main checkout keeps ff-tracking origin/main HEAD.
  Inside a worktree the two git-dir values differ and the hook falls
  through silently. `git checkout <existing-branch>`, `git checkout --
  <file>`, and unrelated commands pass through. `git switch -c <branch>`
  is out of scope for now (potential follow-up). Sibling guard
  `check_main_fresh_before_worktree.sh` already covers the inverse
  failure mode (worktree add from a stale main). Lift mechanism re-uses
  the `/tmp` checkpoint protocol (ADR-00000002 / #117). 14 new bats
  cases; TEST.md total 695 -> 709; shellcheck hook count 30 -> 31.
  `.claude/instincts.yaml` gains a `worktree-for-branch` `bash_command`
  instinct. Refs PR #89 (precedent incident where local main grew a
  branch on a stale base and required a forced rebase) + ADR-00000006.

- `.claude/hooks/enforce_batch_via_script.sh` -- BLOCKING PreToolUse Bash
  hook (refs #121, Tier 2 of #116 hook 2 of 4). DENIES ad-hoc cross-repo
  for-loops performing state-changing operations (`git push|reset|tag|
  branch -D`, or `gh issue|pr close|merge|comment --body`). The two
  detection clauses (for-loop signature AND mutating op in the same
  command) must both hold; standalone mutating commands and read-only
  loops (`gh pr view`, `git log`, `grep`, `cat`) pass through silently;
  invocations of `.claude/scripts/<name>.sh` are also exempt (the
  permanent wrappers the hook nudges the agent TOWARD). Lift mechanism
  re-uses the `/tmp` checkpoint protocol (ADR-00000002 / #117) -- the
  deny message quotes the matching `touch <ack-file>` command, and a
  second attempt of the same loop is allowed through (sha256(cmd) hash
  isolation keeps unrelated loops from sharing acks). `.claude/settings.json`
  registers the hook after `enforce_make_first_upgrade.sh`;
  `.claude/instincts.yaml` gains a `batch-via-script` `bash_command`
  instinct. 19 new bats cases; TEST.md total 676 -> 695; shellcheck hook
  count 29 -> 30. Why: CLAUDE.md cross-repo mutation rule has been prose
  only until now -- an N-iteration loop creates N user prompts and
  induces yes-fatigue, effectively bypassing every ask rule downstream.

### Changed
- `.claude/hooks/remind_make_first_upgrade.sh` (remind-only) replaced with
  `.claude/hooks/enforce_make_first_upgrade.sh` (BLOCKING). Direct
  `./.base/upgrade.sh` invocation is now denied when the repo has a
  `Makefile.ci` with an `upgrade:` target, routing the agent through the
  canonical `make -f Makefile.ci upgrade VERSION=vX.Y.Z` wrapper that runs
  the init.sh symlink resync + main.yaml `@tag` sed steps direct `.sh`
  invocation skips (refs issue #36 incident + ADR-00000005). The deny can
  be lifted via the `/tmp` checkpoint protocol (ADR-00000002 / #117): the
  hook writes a five-section checkpoint markdown + quotes the matching
  `touch <ack-file>` command; the second attempt of the same cmd is
  allowed through (sha256(cmd) hash isolation keeps unrelated commands
  from sharing acks). `.claude/settings.json` PreToolUse Bash chain swaps
  the entry; `.claude/instincts.yaml` gains a `make-first-upgrade`
  `bash_command` instinct. 12 new bats cases replace 8 old; TEST.md total
  672 -> 676. Tier 2 of #116, hook 1 of 4 -- refs #120.

### Added
- 4 historical-rationale ADRs (ADR-00000004 through ADR-00000007) --
  formal records for D-class CLAUDE.md content (4 of 64 sections in the
  #116 master table). Each follows the 5-section template (Date /
  Status / Context / Decision / Alternatives / Consequences):
  - ADR-00000004 `template-rename-to-base` -- why the GitHub repo
    renamed from `template` to `base` + why local folder rename is
    deferred to a separate PR.
  - ADR-00000005 `prefer-make-over-raw-upgrade-sh` -- why
    `make -f Makefile.ci upgrade VERSION=vX.Y.Z` is canonical and
    `./.base/upgrade.sh` is fallback only. Cites #36 incident.
  - ADR-00000006 `git-worktree-mandatory-for-branches` -- why all
    non-main work lives in `worktree/<repo>-<N>/` and why main must
    continuously ff-track `origin/main`. Cites PR #89 precedent.
  - ADR-00000007 `slash-command-first-over-ad-hoc` -- why documented
    slash commands / skills take precedence over raw git/gh/make
    invocations. Cites #36 + `enforce_semver_tag_via_script.sh`
    blocking enforcement.
  CLAUDE.md is NOT modified by this PR; Sub#11 of #116 deletes the
  prose that these ADRs replace. Tier 1 of #116 -- refs #119.
- `CONTEXT.md` (new file at repo root, 13 sections) + ADR-00000003 --
  the structural foundation for the CLAUDE.md slim refactor. Class C
  (domain knowledge, 28 of 64 CLAUDE.md sections per the #116 master
  table) is lifted verbatim into a single sectioned reference manual
  alongside CLAUDE.md / ADRs. ADR records the rationale + three
  rejected alternatives (`doc/claude/*.md` multi-file split from #112,
  `@import` always-inline, `@import` on-demand). CLAUDE.md is NOT
  modified by this PR -- the slim pass that deletes the migrated
  content lands in Sub#11 of #116. Tier 1 of #116 -- refs #118.
- `.claude/hooks/auto_allow_touch_ack.sh` +
  `.claude/scripts/lib/checkpoint.sh` + ADR-00000002 -- foundation for
  the `/tmp` checkpoint protocol that the four Tier 2 E2 enforcement
  hooks (`enforce_make_first_upgrade` / `enforce_batch_via_script` /
  `enforce_worktree_for_branch` / `enforce_slash_command_first`) will
  share. PreToolUse Bash hook auto-allows
  `touch $TMPDIR/claude-checkpoint-<slug>-<session>-<hash>.ack` (the
  one-click ack the protocol writes into its checkpoint markdown);
  helper module exports `write_checkpoint <slug> <cmd> <reason>
  <canonical> <ack_hint>` (renders 5-section markdown) and
  `is_acked <slug> <cmd>` (short-circuits on second attempt). ADR
  records the design + three rejected alternatives (raw deny / state
  file in `.claude/state/` / always-prompt). 14 new bats cases
  (positive / negative / boundary). Tier 0 of #116 -- refs #117.
- `.claude/skills/wait-gh-state/SKILL.md` + `.claude/scripts/wait-issue-close.sh`
  + `.claude/scripts/wait-release.sh` -- sibling skill to `wait-pr-ci`
  that watches non-CI GitHub state transitions (issue close, release
  tag) via `Monitor`. Standardises a pattern hand-rolled four times in
  one session (`base#367`, `base#368` close watchers + two release-
  stable watchers in the `ros1_bridge#107` adoption work). Same exit
  codes (0 = triggered, 2 = arg error, 124 = max-iter), same
  per-transition snapshot + `---` output as the `wait-pr-ci` family.
  `wait-release.sh` classifies each new tag as `rc` (substring `-rc`)
  or `stable` and exits 0 on the first stable match; RC dedup keeps the
  snapshot quiet across polls. 25 new bats cases (12 issue-close + 13
  release). Refs #115.

### Fixed
- `.claude/scripts/wait-pr-ci.sh` + `wait-pr-ci-batch.sh` -- detect
  `state=MERGED` / `state=CLOSED` as terminal states to close the
  auto-merge race (refs #113). After `gh pr merge --auto` completes,
  GitHub stops recomputing `mergeable`, leaving it stuck at `UNKNOWN`;
  the previous gate `all-pass AND mergeable=MERGEABLE -> ALL_DONE`
  hung the Monitor stream until `--max-iterations` / `timeout_ms`. The
  `.state` field is now added to the `gh pr view --json` projection
  and short-circuits the per-PR (or per-pair) loop: `MERGED` -> ready
  with `state=MERGED (auto-merge completed)` snapshot line; `CLOSED`
  without merge -> `FAIL <pr> (state=CLOSED without merge)`. Absent
  `.state` (legacy mocks) falls through to the original mergeable +
  rollup machinery, preserving backwards-compat. Mid-poll transitions
  (poll 1 OPEN/pending -> poll 2 MERGED) also reach `ALL_DONE`
  cleanly. 7 new bats cases (4 single-repo + 3 batch). Hit four times
  in a session this week: `base#363`, `base#369`, `base#373`,
  `docker_harness#104`.

### Added
- `.claude/hooks/check_no_off_task_suggestions.sh` (Stop hook) +
  `.claude/memory/feedback_no_off_task_suggestions.md` -- ban
  Claude-initiated off-task suggestions in session output (user
  breaks, meals, wellness, schedule management; refs #109). Scans the
  last assistant text message of the transcript via regex
  alternation; emits a remind `systemMessage` identifying the matched
  phrase when hit and never blocks (the output has already been
  emitted by the time Stop fires). Throttled once per session per
  matched phrase via `$TMPDIR/claude-no-off-task-<session>-<hash>`.
  Configurable via `NO_OFF_TASK_REMIND_DISABLE=1`. 11 new bats cases.
  Note: the issue body's Layer B (CLAUDE.md "Text output" section
  addition) is reinterpreted -- the "Text output" guidelines the issue
  references live in Claude Code's built-in system prompt, not in
  project `CLAUDE.md`. Layer A (memory entry, auto-loaded into
  context) + Layer C (Stop hook signal) cover the rule.
- `/adr <slug>` slash command + `.claude/scripts/new-adr.sh` +
  `.claude/hooks/remind_adr_on_design_decision.sh` (Stop hook) --
  Architecture Decision Record convention (issue #97). Captures
  "why we chose X over Y" rationale that doesn't fit any other
  artifact slot. Per-repo `doc/adr/NNNNNNNN-<slug>.md` with 5
  sections (Date / Status / Context / Decision / Alternatives /
  Consequences). Auto-numbering scans `doc/adr/[0-9]*.md` for
  max+1; 8-digit zero-padded; numbers never reused. The Stop
  hook reads the session transcript, counts rationale-shaped
  exchanges (alternative / trade-off / rejected because /
  why not / decided to / out of scope because; case-insensitive),
  and nudges `/adr` if threshold met (default 3) and no
  `doc/adr/` Write/Edit happened. Configurable via
  `ADR_REMIND_DISABLE` and `ADR_REMIND_THRESHOLD`. Bootstrap
  `doc/adr/00000001-why-adr.md` records the convention itself.
  28 new bats cases.
- `.claude/scripts/rebase-pr.sh` + `.claude/skills/rebase-pr/SKILL.md`
  -- one-shot rebase + force-push for a PR whose base branch has
  moved (`mergeStateStatus: BEHIND` / `CONFLICTING`; refs #87).
  Auto-resolves the target worktree by scanning
  `${WORKSPACE_DIR:-${PWD}}/worktree/*` for a branch matching the
  PR's head ref; `--worktree <path>` overrides; `--dry-run` previews.
  Exit codes: 0 success, 1 fetch/rebase failure, 2 conflict (prints
  conflicted file list + recovery steps), 3 pre-condition failure.
  `wait-pr-ci.sh` now detects `mergeable=CONFLICTING` and emits
  `FAIL <pr> (mergeable=CONFLICTING)` with the canonical
  `rebase-pr.sh` incantation instead of looping forever waiting
  for `MERGEABLE`. 14 new bats cases on `rebase_pr_spec.bats` + 1
  regression case on `wait_pr_ci_spec.bats`.
- `enforce_gh_body_file.sh` rule 9 -- `gh issue create` must carry
  `--label <non-empty>` (#91). PRs are exempt (they inherit labels
  from the closed issue). `gh-artifact-format/SKILL.md` Section 6
  documents the title-type -> label mapping
  (feat/refactor/chore/track -> enhancement; fix -> bug; docs ->
  documentation). `batch-open-archive-rename-issues.sh` updated to
  pass `--label enhancement` (chore-type titles). 8 new bats cases
  cover the rule (with-label, label= form, -l short, quoted multi-word,
  two-label, empty quoted, empty after equals, PR exempt). Closes the
  "every fresh issue lands in /issue-check Untriaged bucket" gap.
- `.claude/scripts/release-tag.sh` + `.claude/hooks/enforce_semver_tag_via_script.sh`
  + `.claude/skills/semver-bump/SKILL.md` -- canonical script + boundary
  hook + skill enforcing the project's semver workflow (issue #106):
  - **X bump** (`vX.0.0` where X bumped from prev): requires explicit
    user consent via `RELEASE_X_BUMP_ACK=<exact-tag>` env. Claude must
    not set this on its own initiative; the value must come from a
    user explicit OK in conversation.
  - **Y bump** (`vX.Y.0` where Y bumped): requires a prior
    `vX.Y.0-rcN` tag with CI all `success`/`skipped`. Y now covers
    both feature changes AND breaking changes (the old "MAJOR = breaking"
    rule is retired; breaking changes go to Y, X is purely ceremonial).
  - **Z bump** (`vX.Y.Z` where Z>0): bug fix only. Direct tag, no RC,
    no ACK.
  - **RC tag itself** (`vX.Y.Z-rcN`): direct, no further checks.
  - `.version` (when present) must equal the tag literal.
  The hook BLOCKs raw `git tag v*` / `git push.*v[0-9]` / `git push --tags`
  to force routing through the script. `check_tag_version_consistency.sh`
  remains as a defensive second layer for `.version` integrity.
  `/release` slash command updated to invoke `release-tag.sh`; CLAUDE.md
  "version conventions" section rewritten to reflect the new X/Y/Z
  semantics; `instincts.yaml` gets a `semver-tag-via-script` entry.

### Changed
- `wait-pr-ci` skill (`.claude/scripts/wait-pr-ci.sh` +
  `wait-pr-ci-batch.sh` + `wait-tag-ci.sh`) now treats `SKIPPED`
  (uppercase for PR rollups, lowercase `skipped` for tag run-lists)
  as success-equivalent in the all-pass / ALL_DONE check (refs #86).
  GitHub itself treats `SKIPPED` as non-blocking for branch
  protection. Previously the script required strict `SUCCESS` and
  hung forever when a job-level `if:` evaluated false (e.g. the
  doc-only short-circuit pattern from base#317, where `integration-e2e`
  / `behavioural` skip when `needs.classify.outputs.code_changed`
  is false). `FAILURE` / `CANCELLED` / `TIMED_OUT` still trip `FAIL`.
  SKILL.md `## Behaviour (both scripts)` documents the new semantics.

### Added
- `.claude/scripts/fix-dockerfile-copy-script.sh` -- permanent
  helper for the v0.31.0 fanout flow. Patches downstream
  Dockerfiles that lint wrappers via `COPY *.sh /lint/` to
  `COPY script/*.sh /lint/`, because base v0.31.0 (#330) moves
  the seven user-facing wrappers from the repo root into a
  `script/` subfolder. Without the patch, post-upgrade smoke
  tests fail on `build.sh -h exits 0` /
  `run.sh contains XDG_SESSION_TYPE check`
  (`grep /lint/run.sh: No such file or directory`). Shape
  mirrors `fix-dockerfile-lint-lib.sh` (#284 sub-libs split
  fanout): `--branch <name>` required, `--org` / `--repos` /
  `--dry-run` optional, idempotent grep-guards on both new and
  old patterns. Default repo set is the 2 active downstream
  (`ros_distro` / `ros2_distro`) per `/batch-template-upgrade`
  DEFAULT_REPOS. Surfaced during base v0.31.0-rc1 RC
  validation on `env/ros_distro` (commit `32624a3` on closed
  RC PR ycpss91255-docker/ros_distro#23).
- `.claude/instincts.yaml` + `.claude/scripts/instinct-query.sh` +
  `.claude/scripts/_instinct_parser.py` -- pilot for issue #95: a
  structured, machine-readable store of repo conventions (shell
  style, commit-title shape, PR / issue body rules, gh artifact
  routing, TDD test-category mapping, etc.) that hooks / skills /
  commands can query instead of grepping CLAUDE.md prose. The
  query script accepts `<kind> [path]` and `--list`; trigger kinds
  are `file_edit` (with optional `glob` + `not_glob`),
  `git_commit`, `gh_pr_create`, `gh_issue_create`, `bash_command`.
  The parser is a 60-line stdlib-only subset reader (no PyYAML
  dependency, so the Alpine test container does not need an extra
  package). `remind_tdd_categories.sh` is the proof-of-concept
  consumer: when it fires the TDD reminder it appends the matching
  instincts so the conventions land in the same systemMessage.
  `.claude/scripts/check-claude-md-tree.sh` ignores `__pycache__/`
  emitted on-demand by Python helper imports.
  CLAUDE.md gains a new "機器可讀 conventions store" sub-section
  under "Process discipline" pointing at the new files. 14 bats
  cases in `instinct_query_spec.bats`. Closes #95.

### Changed
- Documentation cleanup: replace lingering `template` references with
  `base` (the renamed upstream repo) and `.base/` (the renamed subtree
  prefix) across `.claude/commands/*.md`, `.claude/skills/wait-pr-ci/SKILL.md`,
  `.claude/hooks/*.sh` advisory text, and CLAUDE.md narrative sections.
  Audit checklist `audit.md` swaps `.template_version` -> `.base/.version`
  (the version tracker file was renamed in `base@v0.25.0`; the legacy
  filename no longer exists). The slash command and script names
  (`/batch-template-upgrade`, `batch-template-upgrade.sh`,
  `check-template-versions.sh`, `batch-rename-template-to-base.sh`,
  `batch-template-pr-body.template.md`) keep their original spelling
  for backward compatibility; only the narrative was updated.
- `remind_subtree_init.sh` trigger pattern now matches both legacy
  `template` and current `.base` in `git subtree pull` commands, so
  the reminder still fires for the new `--prefix=.base` form.

### Added
- `.claude/commands/verify.md` + `.claude/scripts/verify.sh` -- new
  `/verify` slash command and underlying script that runs the
  project's change-complete checklist (CLAUDE.md「變更完成
  checklist」) in one pass. Seven phases: `shellcheck` /
  `hadolint` / `bats` (hard — exit 1 on fail, short-circuit later
  phases unless `--continue-on-fail`), then `tree-audit` /
  `test-md` / `doc-scan` / `diff-stats` (soft — flag in summary,
  do not abort). Flags: `--dry-run` (plan only), `--phase <name>`
  (repeatable, narrow to a subset), `--base <ref>` (diff base for
  `diff-stats` + `doc-scan`, default `origin/main`),
  `--repo-root <path>` (override `${CLAUDE_PROJECT_DIR}` / git
  toplevel). Final output is a markdown `## Verify summary` table
  mapping each phase to `pass` / `fail` / `skipped`. 15 bats
  cases in `verify_spec.bats`. CLAUDE.md "變更完成 checklist"
  section gains a "Canonical entry" paragraph pointing here.
  Closes #93.
- `.claude/memory/` -- 15 per-project memory files moved into the repo
  (was previously in `~/.claude/projects/<encoded-workspace-path>/memory/`,
  which is workspace-path-coupled and lost across machine moves). The
  expected Claude Code location is now reached via symlink (see
  `setup-memory-link.sh` below). Memory now ports with the repo and
  appears in git history.
- `.claude/scripts/setup-memory-link.sh` -- new clone / new machine
  setup helper. Detects workspace, computes
  `~/.claude/projects/<encoded-path>/memory/` (workspace path with `/`
  -> `-`), and creates the symlink to `<workspace>/.claude/memory/`.
  Idempotent: re-running on a correct setup is a no-op; wrong-target
  symlinks get replaced; matching-content dirs get rm'd + symlinked;
  diverged-content dirs are refused without `--force` (with `--force`
  the existing dir is backed up to `.backup-<timestamp>` before
  replacement). `--dry-run`, `--workspace`, `--home` overrides. 14
  bats cases in `setup_memory_link_spec.bats`.
- `CLAUDE.md` -- new "Per-project memory (repo-portable via symlink)"
  section explaining the rationale, directory shape, setup command,
  and reminding that per-file frontmatter rules (`name` /
  `description` / `metadata.type` + `MEMORY.md` index) are unchanged.

### Fixed
- `.claude/hooks/remind_strategic_compact.sh` -- removed
  `hookSpecificOutput` from the emitted JSON. Stop event schema only
  accepts top-level `systemMessage` / `decision` / `reason` /
  `continue` / `suppressOutput` / `stopReason`; `hookSpecificOutput`
  is reserved for PreToolUse / UserPromptSubmit / PostToolUse /
  PostToolBatch. The previous output (introduced in PR #96 / closes
  #92) triggered "Hook JSON output validation failed" in Claude Code
  on every fire. Added regression test
  `fired output omits hookSpecificOutput` to lock the shape.
- `.claude/hooks/remind_strategic_compact.sh` -- Stop hook that reads
  the session transcript and proposes `/compact` at task boundaries.
  Two signals (any one fires the proposal): `gh pr merge` Bash
  invocation in this session OR total tool-call count reaching
  `STRATEGIC_COMPACT_TOOL_THRESHOLD` (default 50). Non-blocking
  (hook output schema does not support triggering `/compact`
  directly). Throttled once per session per signal-set hash via a
  marker file in `${TMPDIR:-/tmp}`. Disable per-session with
  `STRATEGIC_COMPACT_DISABLE=1`. 18 bats cases in
  `remind_strategic_compact_spec.bats`. Closes #92.
- `.claude/skills/strategic-compact/SKILL.md` -- companion rubric:
  when to manually `/compact` (PR just merged, TaskList all-done,
  exploration distilled into a plan, > 50 tool calls without compact,
  task-transition boundary) vs when NOT to (mid-implementation,
  debugging a specific failure, just received user feedback mid-turn,
  holding non-trivial in-memory state). Pre-compaction checklist
  (write down anything not yet on disk / TodoWrite / CLAUDE.md /
  memory before compacting). Inspired by
  `affaan-m/everything-claude-code`'s `strategic-compact` skill.
- `.claude/hooks/remind_main_sync.sh` -- PreToolUse non-blocking
  reminder on `gh pr merge`. Two variants by presence of `--auto`:
  "auto-merge queued, pull main after CI passes" vs "PR merged, pull
  main now". 16 bats cases in `remind_main_sync_spec.bats`.
- `.claude/hooks/check_main_fresh_before_worktree.sh` -- PreToolUse
  BLOCKING on `git worktree add ... main` (or `... origin/main`). Runs
  `git fetch --quiet origin main` then compares `rev-list --count
  main..origin/main`; denies with a concrete `git pull --ff-only`
  instruction when local main is behind. Degraded paths (non-git cwd,
  fetch failure, no origin/main yet) silently allow. 14 bats cases in
  `check_main_fresh_before_worktree_spec.bats` (uses local bare-repo
  origin fixture so the fetch path runs without network access).
  Pairs with the rule supplement in CLAUDE.md「Git 工作流程 > 主
  checkout 狀態」: "停在 origin/main" means continuously ff-tracking
  origin/main HEAD, not freezing at a commit. PR #89 precedent: a
  worktree branched off stale local main forced a mid-PR rebase when
  upstream moved.
- `.claude/scripts/fix-dockerfile-lint-lib.sh` -- generalised replacement
  for the one-shot v0.28.1 fanout fix. Patches downstream Dockerfiles
  that pre-date #284's `_lib.sh` -> `lib/*.sh` sub-libs split, adding
  `COPY .base/script/docker/lib /lint/lib` before the `RUN shellcheck`
  anchor and extending the shellcheck invocation to also cover
  `/lint/lib/*.sh`. Takes `--branch <name>` (required) so each fanout
  cycle targets its own `chore/template-vX.Y.Z` branch instead of
  growing one-shot scripts per version. Idempotent: re-runs on
  already-patched Dockerfiles are no-ops. 6 bats cases in
  `fix_dockerfile_lint_lib_spec.bats` covering arg parsing, --help,
  --dry-run plan output, --repos CSV narrowing, and --org override.
  Long-term root cause (downstream Dockerfile drift outliving subtree
  pulls) is tracked separately for an upgrade.sh auto-patch.
- `.claude/scripts/batch-open-archive-rename-issues.sh` -- one-shot batch
  opener for 11 follow-up issues across downstream repos parked from
  docker_harness's active upgrade list: 7 archive issues (`agent/ai_agent`,
  `claude_code`, `codex_cli`, `gemini_cli`, plus `app/ros1_bridge`,
  `sick_humble`, `sick_noetic` — superseded by `env/ros_distro` +
  `env/ros2_distro`) and 4 sensor rename + `template/` -> `.base/`
  migration issues (`urg_node_humble` -> `urg_node_ros2`, `urg_node_noetic`
  -> `urg_node_ros`, `realsense_humble` -> `realsense_ros2`,
  `realsense_noetic` -> `realsense_ros`). Bodies written to
  `${TMPDIR:-/tmp}/issue-{archive,rename}-<repo>.md` then `gh issue
  create --body-file` (per `enforce_gh_body_file.sh` rule 1); idempotent
  via exact-title check skipping repos that already have a matching
  issue. `--only`, `--owner`, `--refs`, `--dry-run` supported. 16 bats
  cases in `batch_open_archive_rename_issues_spec.bats`.
- `.claude/scripts/batch-pr-close.sh` -- batch close N `<repo>:<pr>`
  pairs in a single invocation, with a required `--reason` posted as a
  uniform PR comment before close. Sibling of `batch-pr-merge.sh` for
  the "supersession" half of the lifecycle (the original use case: 13
  in-flight v0.28.1 fanout PRs retired in favour of v0.28.2 re-fanout
  after the SSH X11 hotfix landed). Short `<repo>` form auto-prefixed
  with the default owner; `--no-delete-branch` opt-out for the default
  branch-delete behaviour; `--dry-run` for plan inspection. 16 bats
  cases in `batch_pr_close_spec.bats`. Closes the cross-repo
  batch-mutation gap flagged in CLAUDE.md's "跨 repo 批次 mutation
  規範" -- N individual `gh pr close` calls trigger yes-fatigue and
  effectively bypass the single-prompt ask gate.
- `.claude/skills/gh-artifact-format/SKILL.md` -- format guidance for
  GitHub artifacts (issue title, issue body 5 sections, close-comment
  3 tiers, non-closing comment 3 categories, cross-ref keyword
  vocabulary). Paired with the renamed
  `.claude/hooks/enforce_gh_body_file.sh` hook: the skill is the
  content rules (what shape an issue body takes), the hook is the
  routing rules (long body must land in /tmp/<name>.md and pass
  --body-file). Closes #64.

### Fixed
- `.claude/hooks/remind_main_sync.sh` -- regex anchored to command
  boundary + quoted regions stripped before matching, so commit
  messages and `grep` patterns containing the literal `gh pr merge`
  no longer trigger the reminder. Originally introduced in PR #90,
  the naive `[[ cmd =~ gh\s+pr\s+merge ]]` regex fired on every
  `git commit -m "...gh pr merge..."` (the commit message body that
  describes the hook itself triggered it). Fix: strip `"..."` and
  `'...'` regions via sed first, then require `gh pr merge` to
  appear at start-of-string or after one of `;` `&` `|` `$(`
  (with optional whitespace). 7 new regression specs cover the
  false-positive cases plus the boundary anchors.

### Changed
- `.claude/settings.json` -- registers `remind_main_sync.sh` and
  `check_main_fresh_before_worktree.sh` under the PreToolUse Bash
  matcher (16 entries total).
- `CLAUDE.md`「Git 工作流程 > 主 checkout 狀態」row clarified: "停在
  origin/main" means continuously ff-tracking origin/main HEAD (run
  `git pull --ff-only origin main` after every PR merge), not freezing
  at a commit. Cites the two new hooks (`remind_main_sync.sh` reminds,
  `check_main_fresh_before_worktree.sh` blocks worktree-from-stale).
  Hooks tree listing in CLAUDE.md updated.
- `.claude/scripts/batch-template-upgrade.sh`,
  `check-template-versions.sh`, `batch-gitignore-add-line.sh` -- shrunk
  `DEFAULT_REPOS` active list from 13 to 2 (`env/ros_distro` +
  `env/ros2_distro`). The other 11 downstream repos (4 agent + 3 ROS
  app + 4 sensor) are commented out with a header note explaining the
  reason (archive pending for 7, rename + `.base` subtree migration
  pending for 4 sensor repos). Companion
  `batch-open-archive-rename-issues.sh` opens the 11 follow-up issues
  that gate uncommenting each entry. `CLAUDE.md` directory tree
  annotated with per-repo status (`archive 待辦` /
  `rename -> <new> + template/->.base/ 待辦`); "主 checkout 狀態" row
  in Git workflow section updated from "13 個 active" to "2 個 active +
  11 待 follow-up".
- `.claude/hooks/remind_use_body_file.sh` -- renamed to
  `enforce_gh_body_file.sh`, switched from non-blocking PostToolUse
  remind to PreToolUse BLOCKING deny. Implements 8 rules from #64
  discussion:
  1. `gh issue create` without `--body-file <path>` -> deny.
  2. `gh issue comment` with `--body|--comment` longer than 80 chars
     or multi-line -> deny (short inline OK).
  3. `gh issue close --comment` (any inline) -> deny -- enforce
     two-step: `gh issue comment N --body-file X` then
     `gh issue close N [--reason ...]`.
  4. `gh pr create` without `--body-file <path>` -> deny.
  5. `gh pr comment` with long `--body` -> deny (80-char threshold
     same as rule 2).
  6. `gh pr edit --body` inline -> deny (always file).
  7. `gh pr review --body` longer than 80 chars or multi-line ->
     deny.
  8. `--body "$(cat ...)"` or `--body-file - <<EOF` heredoc on any
     gh subcommand -> deny (parser-fallback patterns from CLAUDE.md
     "Bash parser limits" table).
  Threshold (SHORT_LIMIT = 80 chars, single line) applies uniformly
  across rules 2/5/7. Trivial close routes through two-step where
  the comment half can be inline if short enough. Bats coverage:
  33 specs in
  `.claude/hooks/test/smoke/enforce_gh_body_file_spec.bats` (vs 9
  in the old `remind_use_body_file_spec.bats`).
- `.claude/settings.json` hook registration: pointer updated from
  `remind_use_body_file.sh` -> `enforce_gh_body_file.sh`.
- `CLAUDE.md`「Bash 命令寫法的 parser 限制」table row for the
  `gh ... --body "$(cat)"` pattern now mentions the BLOCK semantics
  and links the new skill. Bottom of section: the
  "two hooks remind" bullet list becomes "remind +
  enforce" with the enforce entry pointing at #64.
- `.claude/settings.json` sandbox `excludedCommands` adds
  `.claude/scripts/*` so wrappers under `.claude/scripts/` bypass
  bubblewrap. Resolves the recurring `bwrap: Can't create file at
  /home/yunchien/workspace/docker/<repo>/.claude: Is a directory`
  error that hit every `Monitor` / `Bash` invocation of
  `.claude/scripts/wait-pr-ci.sh` (and friends) when cwd was a
  downstream-repo worktree -- the downstream `.claude` is a symlink
  to the workspace root, and bwrap's bind-mount setup chokes when it
  tries to overlay something on that symlink target. Previously every
  call needed `dangerouslyDisableSandbox: true` and a per-invocation
  user prompt. Trust boundary remains: `.claude/scripts/` is
  repo-owned + PR-reviewed, same level as the existing `docker *` /
  `./build.sh *` excludes already on the list. The doc snippet in
  CLAUDE.md「Sandbox baseline」section and the table row for
  `excludedCommands` were updated to match. Closes #77 sub-task 3.

### Added
- `.claude/scripts/ci-wall-time-compare.sh` helper -- fetches per-job
  `gh run view --json jobs` for a baseline + fixed run id of the same
  workflow, computes wall time delta per job and overall, and emits a
  markdown table (`| shard | baseline | fixed | delta |` rows + a
  `**total wall**` summary row) suitable for pasting into a CI-perf
  PR body. Args: `--repo OWNER/REPO --baseline RUN-ID --fixed RUN-ID
  [--output PATH]`. Exits 2 when any job is still in-progress
  (missing `startedAt` or `completedAt`), 1 on `gh` API failure.
  Replaces the manual `gh run view --jq` + spreadsheet workflow used
  for the ros1_bridge `-j` auto-detect benchmark (template#272 cache
  refinement, template#273 doc-only PR skip, and other CI-perf PRs
  in flight). Bats coverage: 14 specs in
  `.claude/hooks/test/smoke/ci_wall_time_compare_spec.bats` covering
  flag validation, faster / slower / equal-duration deltas, inner-
  join of jobs (skip jobs present in only one run), in-progress
  guards on either side, gh API failure propagation, and the
  `--output` file path. Closes #77 sub-task 2.
- `.claude/hooks/check_no_stale_template_refs.sh` PostToolUse hook --
  fires on Edit / Write / MultiEdit of `.base/**/*.sh`,
  `.base/**/Makefile*`, `.base/**/Dockerfile*`, `.base/**/*.mk` and
  emits a non-blocking systemMessage when the touched file contains
  stale `template/<path>` references (any of `template/script/`,
  `template/init.sh`, `template/upgrade.sh`, `template/_lib`,
  `template/setup.conf`, `template/dockerfile/`, `template/test/`,
  `template/config/`, `template/Makefile`). Catches the drift at Edit
  time so the developer fixes the rename while in flow rather than
  waiting for fresh-clone breakage (refs base#282 — the v0.25.0
  rename moved `template/` -> `.base/` physically but left `_lib.sh`
  refs pointing at the old path, which CI never exercised because
  `Makefile.ci` paths bypassed the wrapper symlinks). Hook self,
  `.claude/hooks/test/` fixtures, `.md` files, and files outside
  `.base/` are all skipped. Bats coverage: 12 specs in
  `.claude/hooks/test/smoke/check_no_stale_template_refs_spec.bats`
  (positive: `template/script/docker`, `template/init.sh`,
  `template/upgrade.sh`, `template/dockerfile/`, `template/Makefile`,
  Dockerfile under `.base/`; negative: clean `.base/` ref, literal
  `template/` in `archive/`, `.md` file, non-shell file, missing
  file, empty input). Closes #77 sub-task 1.

### Changed
- `/pr` slash command (`.claude/commands/pr.md`): step 5 now appends
  `gh pr merge <N> --auto --squash --delete-branch` right after
  `gh pr create`, so GitHub auto-merges the PR once required status
  checks pass and the branch is up to date. Step 6 (`wait-pr-ci`) is
  reserved for cases that need merged state mid-session (template
  repo + tag + downstream fanout, or chained workflows). Auto-merge
  requires `allow_auto_merge=true` on the repo; batch-enabled on all
  16 active `ycpss91255-docker` repos via
  `gh repo edit <repo> --enable-auto-merge` on 2026-05-13. `.github`
  intentionally kept at `false` — its `paths:` filter leaves the
  `lint` status check pending on doc-only PRs which would stall
  auto-merge indefinitely (refs the existing wait-pr-ci `.github`
  carve-out at line 92-101). BEHIND resolution: dependabot PRs get
  an `@dependabot rebase` comment; ordinary PRs get a local
  `git pull --rebase origin main` + force-push.
- `/pr` slash command description (first line, surfaced as the
  skill's auto-trigger blurb) gains an explicit `TRIGGER when:` cue
  listing the file classes (`*.sh`, `Dockerfile`, `compose.yaml`,
  `.github/workflows/*`, `.claude/**`, etc.) and natural-language
  phrasings (「處理 xxx」「修 xxx」「加 --foo flag」「重構 yyy」)
  that should make Claude proactively apply the PR workflow without
  waiting for the user to type `/pr` literally. Backstops the
  CLAUDE.md「Process discipline — slash command / skill 優先於
  ad-hoc 執行」rule that the prior generic description failed to
  enforce in practice.
- `doc/test/TEST.md` test-row descriptions migrated `template/...` ->
  `.base/...` to match the actual bats specs (which already use
  `.base/` paths since the post-#67 template -> base rename and the
  PR #72 fanout). Affected sections:
  `remind_readme_on_core_script_spec.bats`,
  `check_readme_framework_spec.bats`,
  `check_template_versions_spec.bats`,
  `check_tag_version_consistency_spec.bats`,
  `remind_make_first_upgrade_spec.bats`. Pure doc-sync — no spec or
  hook change. The local docker_harness `template/` folder is left
  in place per CLAUDE.md note (folder rename is deferred).
- `remind_tdd_categories.sh` PostToolUse hook now detects per-repo
  TDD capability by checking which of `test/smoke`, `test/unit`,
  `test/integration` exist under the repo root, and lists only the
  applicable categories in the reminder (refs #75). Repo root is
  resolved by walking up from the touched file looking for a
  `Dockerfile`, `Makefile.ci`, `.base/`, `template/`, or `init.sh`
  marker. For ros1_bridge-style downstream repos (only `test/smoke/`
  on disk), the reminder lists `Smoke + Lint` instead of the legacy
  `Unit + Smoke + Integration + Lint` claim. For template-style
  repos (all three test subdirs present), the legacy 4-category
  reminder is preserved. Fallback: when none of the three test
  subdirs exist (fresh repo, no infra), claim all three applicable
  so the broad guidance does not regress for new code. +4 bats tests
  in `remind_tdd_categories_spec.bats` (file 8 -> 12); total
  `make -C .claude/test test` rises 324 -> 328.
- `wait-pr-ci/SKILL.md` documents the cwd assumption that the Monitor
  examples carry (refs #63). Monitor inherits the agent's cwd at
  invocation, the relative `.claude/scripts/...` path resolves under
  that cwd, and worktrees of OTHER downstream repos (e.g.
  `worktree/ros1_bridge-NN/`) have no `.claude/scripts/` of their own
  so Monitor exits 127 with no events. `${CLAUDE_PROJECT_DIR}` is set
  only inside hook script env (the `command:` field of `settings.json`
  hook entries), not inside Bash / Monitor tool subprocesses, so it
  cannot be used as a substitute (verified directly:
  `echo "$CLAUDE_PROJECT_DIR"` from Bash returns empty). Recommended
  workaround until a portable absolute-path mechanism lands: ensure
  agent cwd is harness root or a docker_harness worktree before
  launching Monitor, or prefix the command with `cd <harness-root>
  &&`. Doc-only change.

### Fixed
- `wait-pr-ci.sh` and `wait-pr-ci-batch.sh` no longer declare false
  `ALL_DONE` when called immediately after a `git push --force-with-lease`
  while GitHub has not yet retriggered CI on the new head (refs #60). Two
  new guards above the existing `all(.conclusion == "SUCCESS")` jq check:
  (1) a watch-start `completedAt` comparison demotes the rollup to
  `pending` when every matching check's `completedAt` predates the watch
  start time (carry-over results from a prior head); (2) a per-PR /
  per-pair `headRefOid` change check emits one `[head-moved] PR<n>
  <old7>..<new7>` (or `[head-moved] <owner>/<repo>#<pr> ...` for the
  batch script) log line on detection and forces that pair's state to
  `pending` for the same iteration. Both guards apply automatically; no
  new flag required. Backwards-compatible: only fires when every
  matching check has `completedAt` set (real GitHub API always
  populates it; existing test stubs without the field keep working).
  +9 bats tests (5 in `wait_pr_ci_spec.bats`, 4 in
  `wait_pr_ci_batch_spec.bats`); total `make -C .claude/test test`
  rises 309 -> 318.

### Added
- `check_readme_framework.sh` PostToolUse hook now also walks the
  `## Directory Structure` code-fence (English + zh-TW / zh-CN / ja
  headings) and warns when any reconstructed leaf path is not present
  in the repo on disk. Catches the failure mode where a `git mv`
  relocation updated all narrative sections of the README but left
  the inline tree pointing at the old flat layout (the ros1_bridge
  PR #75 yaml rename surfaced the gap that #65 tracks). Each warning
  prints the README line number plus the stale rel-path; symlink
  notation `foo -> target` checks the link (`foo`) not the target,
  so a worktree without `.base/` materialized does not generate
  false positives. Implemented in Python (alpine's awk does not
  handle the multi-byte tree characters reliably). +6 bats tests in
  `check_readme_framework_spec.bats` covering positive control, the
  #65 drift case, ellipsis / pure tree-art tolerance, symlink
  semantics, the zh-TW heading variant, and the no-section degraded
  path.
- New `.claude/scripts/batch-license-apache.sh` — one-shot fanout
  helper that adds Apache 2.0 `LICENSE` + CI / License badges + a
  CHANGELOG entry to each of the 13 active downstream container
  repos. Drives the org-wide license alignment (refs sister issues
  ai_agent#41, claude_code#40, codex_cli#39, gemini_cli#39,
  ros_distro#6, ros2_distro#6, ros1_bridge#66, urg_node_humble#37,
  urg_node_noetic#40, sick_humble#41, sick_noetic#40,
  realsense_humble#41, realsense_noetic#40). Per-repo body /
  changelog generation is templated; main checkout is untouched
  (worktree per repo). One-off but kept under `.claude/scripts/`
  rather than `/tmp/` so the next similar batch (if any) can crib
  from the structure.
- `LICENSE` (Apache 2.0) and CI / License badges in `README.md`
  (#52). Fresh add — repo previously had no LICENSE and no badges.
  Aligns with the org-wide Apache 2.0 migration tracked across 17
  sister repos.
- New PostToolUse hook `.claude/hooks/check_readme_framework.sh` that
  warns when a downstream repo's `README.md` (or one of its three
  `doc/README.<lang>.md` translations) drifts from the canonical
  framework derived from `template/README.md`. The framework was
  applied for the first time on `ros1_bridge` in PR #63 (commit
  148c411); the hook now lets every subsequent fanout edit get
  immediate feedback instead of relying on memory of what the
  framework requires. Fires on Edit / Write / MultiEdit; non-blocking
  (emits `{systemMessage, hookSpecificOutput.additionalContext}` JSON
  the same way `check_test_md_drift.sh` and `check_no_emoji.sh` do).
  Six per-file checks: CI status badge present (matches
  `actions/workflows/main.yaml/badge.svg`), 4-language switch link
  present (`**[English](README.md)**`), no legacy `> **TL;DR**`
  blockquote (must be `## TL;DR` H2), no stale
  `template/build.sh` symlink target (canonical:
  `template/script/docker/build.sh`), no obsolete
  `.template_version` reference (replaced by `template/.version` in
  template v0.16.0), and a Smoke Tests section linking to
  `(doc/test/TEST.md)`. Plus a cross-language drift signal: when the
  English README is the file being edited, the hook also walks the
  three translations and flags any that have not yet adopted the
  framework markers (or are missing entirely). Scope is restricted to
  `agent/<repo>/`, `app/<repo>/`, `env/<repo>/`, and `multi_run/`;
  `template/`, `archive/<repo>/`, and `org-profile/` are skipped (the
  template README is the framework reference itself, the archive is
  read-only, and org-profile is a different artifact). Covered by 14
  new bats specs in `.claude/hooks/test/smoke/check_readme_framework_spec.bats`
  (one per check + drift cases + scope-skip cases + a multi_run smoke
  case); total `make -C .claude/test test` count rises 277 -> 291.

### Changed
- `wait-pr-ci/SKILL.md` notes that `.github` doc-only PRs (most often
  `profile/*.md` README updates) intentionally bypass the `lint` job —
  the workflow's `paths:` filter restricts triggers to `topics.yaml`,
  `script/sync-topics.sh`, and the workflow file itself, so unrelated
  paths produce no check runs and the rollup sits at `no-checks`
  indefinitely (the `.name=="lint"` filter polls forever in that
  state). Skip `wait-pr-ci` and merge directly after review; the
  `.github` repo's branch protection requires a PR but no status
  check. Surfaced after PR ycpss91255-docker/.github#16 hit this
  exact hang.
- `wait-pr-ci/SKILL.md` filter table extended with `docker_harness`
  (`bats + shellcheck + hadolint`) and the post-topics-taxonomy
  `.github` row (`lint`). The previous `.github` row claimed "no CI"
  / `'false'` filter, which became wrong after the topics taxonomy
  PR (ycpss91255-docker/.github#13) added a lint job. CLAUDE.md
  branch protection table + CI monitoring section updated to match,
  plus an explicit note that both repos require an explicit
  `--check-filter` (default matches `test` / `Integration ...` and
  hangs on `no-checks` for these two).

### Added
- `remind_topics_yaml_on_new_repo.sh` PreToolUse hook fires before
  `gh repo create ycpss91255-docker/<name>` and reminds to add the new
  repo to `ycpss91255-docker/.github` topics.yaml so the weekly drift
  cron does not fail. Pairs with the universal CI-side roster check
  (sync-topics.sh roster_drift) for repos created out-of-band.
  `/new-repo` slash command step 8 rewritten: open a `.github` PR
  adding the repo to topics.yaml instead of calling `gh repo edit
  --add-topic` directly (which would drift from the canonical yaml).

### Changed
- `wait-pr-ci-batch.sh` `--check-filter` now accepts a per-repo override
  form `<repo>=<expr>` (repeatable) in addition to the existing global
  jq expression. Pairs that match no per-repo entry fall back to the
  global filter; `<repo>` may be short (`ros_distro`) or full
  (`owner/repo`). Mixed-category batches (single-target containers
  using `call-docker-build / docker-build` plus multi-distro repos
  using `ci-passed` / `ci-summary` aggregators) can now be handled in
  one Monitor pass without three of them silently hanging on
  `no-checks`. `wait-pr-ci/SKILL.md` per-repo filter table extended to
  cover `env/ros_distro`, `env/ros2_distro` (`ci-passed`) and
  `app/ros1_bridge` post-#54 (`ci-summary`); `CLAUDE.md` branch
  protection table + CI monitoring section updated to match. Closes
  #46.
- Repo renamed `claude-workspace` -> `docker_harness` to better reflect
  scope (Docker container monorepo + cross-repo harness, not Claude
  config-only). GitHub redirect keeps old URLs (`gh repo rename` auto
  registers `<owner>/claude-workspace` -> `<owner>/docker_harness`), so
  external links and existing clones continue to resolve. Active code
  and docs scrubbed of `claude-workspace` references; historical
  CHANGELOG entries (lines 284 / 513) kept as-is per "don't rewrite
  history" rule. Test image renamed `claude-workspace-test:local` ->
  `docker_harness-test:local`. Special-case keys in
  `.claude/commands/issue-fix.md` (source-tree map, test runner map,
  CI filter map) retargeted to the new short name.
- **Downstream repo count: 17 -> 13.** The 6 single-distro env repos
  (`ros_noetic`, `ros_kinetic`, `ros2_humble`, `osrf_ros_noetic`,
  `osrf_ros_kinetic`, `osrf_ros2_humble`) were superseded by the new
  `ros_distro` / `ros2_distro` (single Dockerfile + `BASE_IMAGE` ARG +
  4-entry CI matrix per repo) and archived on 2026-05-07. Local
  checkouts moved from `env/` to `archive/`. Workspace .gitignore now
  ignores `archive/*/`. `.claude/scripts/batch-template-upgrade.sh`,
  `.claude/scripts/check-template-versions.sh`,
  `.claude/scripts/batch-gitignore-add-line.sh`, CLAUDE.md tree section,
  and four slash-command docs (`pr.md`, `batch-pr.md`, `release.md`,
  `batch-template-upgrade.md`) updated to reflect the new 13-repo
  set + new env entries.
- `.claude/scripts/batch-pr-merge.sh` now mirrors `wait-pr-ci-batch.sh`'s
  argument contract: short `<repo>` form is auto-prefixed with the default
  owner `ycpss91255-docker`, full `<owner>/<repo>` form is accepted
  unchanged, and a `--owner <OWNER>` flag overrides the default. PR
  numbers are validated up-front (non-numeric rejects with exit 2 before
  any `gh` invocation). Previously, the next-step copy-paste block printed
  by `batch-template-upgrade.sh` worked for `wait-pr-ci-batch.sh` but
  failed across all 17 pairs for `batch-pr-merge.sh` because the latter
  required the explicit owner prefix. The next-step block now works
  verbatim for both. 14 new bats specs in
  `.claude/hooks/test/smoke/batch_pr_merge_spec.bats` covering arg
  parsing, normalization, dry-run, gh failure handling, and mixed
  success/failure batches.

### Fixed
- `.claude/settings.json` `sandbox` block now declares
  `excludedCommands: ["docker *", "make *", "./build.sh *",
  "./run.sh *", "./exec.sh *", "./stop.sh *"]`. Closes #39 — the
  long-standing conflict where the project's "all verification via
  Docker" rule was incompatible with sandbox's blocking of
  `connect(AF_UNIX, /var/run/docker.sock)`. Anthropic's official
  sandboxing docs explicitly recommend listing docker in
  `excludedCommands`; the wildcard pattern (`docker *`) follows the
  same prefix-match syntax used by `permissions.allow`. With this
  fix, `make -C .claude/test check` / `docker version` /
  `docker ps` / `./build.sh test` etc. all run unsandboxed without
  needing per-call `dangerouslyDisableSandbox: true`. Verified
  locally: 257-test hook suite passes plain `make -C .claude/test
  check` (no disable flag).

### Changed
- CLAUDE.md「Sandbox baseline」section updated to document the new
  4th key (`excludedCommands`) alongside `enabled` /
  `autoAllowBashIfSandboxed` / `filesystem.allowWrite`. Previous
  text claimed "3 lines"; now "4 keys" with the rationale and link
  to issue #39 for posterity.
- `.claude/settings.json` permission rules normalized to colon form
  (`Bash(<prefix>:<args>)`). Four entries were still using the
  space-arg form (`Bash(npm list *)`, `Bash(npm root *)`,
  `Bash(npm config *)`, `Bash(bash -c *)`); now all entries use the
  same colon-form for grep-ability and consistency with the rest of
  the file. Behaviour is unchanged — both forms match identically at
  the perm-parser layer. Closes the (5) follow-up from issue #7.
- `.claude/settings.json` is now the **single source of truth** for
  Claude Code settings. Permissions (`allow` / `ask`), `sandbox`
  config, and `prefersReducedMotion` previously lived in the
  gitignored `.claude/settings.local.json`; they are now committed
  in `settings.json` so a fresh clone / new machine inherits the
  full setup without manually re-approving every command. The local
  override file is no longer used by this repo. CLAUDE.md「Sandbox
  baseline」section retitled accordingly.
- `.claude/settings.json` `permissions.ask` extended with
  state-changing docker subcommands: `docker build/run/exec/start/
  stop/restart/compose:*`. Combined with the new
  `check_prefer_dot_sh.sh` hook below, this enforces "use ./build.sh
  / ./run.sh / ./exec.sh / ./stop.sh wrappers, not raw docker"
  across the org's container repos.
- `.claude/settings.json` allow list reduced from ~95 entries to 45
  by removing (a) read-only commands already covered by
  `autoAllowBashIfSandboxed`, (b) duplicate absolute-path forms of
  `.claude/scripts/*.sh`, (c) stale `worktree/template-{199,207,210}`
  paths, (d) redundant hook-script self-invocations, (e) one-shot
  curl probes, (f) `Bash(bash -c *)` (moved to ask — was a permission
  bypass for narrower destructive rules), (g) frozen
  `APT_MIRROR_DEBIAN=...` make variants (let `.env` provide the
  value to docker compose; `Bash(make:*)` covers the bare form).

### Added
- New PreToolUse hook `.claude/hooks/check_prefer_dot_sh.sh` —
  detects `docker build/run/exec/stop` and `docker compose
  <up|down|build|run|exec>` calls. When the cwd has the matching
  `.sh` wrapper (`./build.sh` / `./run.sh` / `./exec.sh` /
  `./stop.sh`), DENIES with a message pointing at the wrapper
  (going through the wrapper picks up `setup.sh` `.env` / compose
  refresh + language env + GPU/GUI detection). When no wrapper is
  available, forces `ask` prompt rather than letting the broader
  `Bash(docker:*)` allow rule pass. Read-only subs (ps / images /
  inspect / logs / pull / ...), make-internal docker compose calls
  (subprocess; not visible to Claude), and destructive subs already
  in `permissions.ask` (rm / rmi / push / kill / ...) stay silent.
  19 bats specs cover the wrapper-present / wrapper-absent / silent
  matrix plus env-prefix stripping (`BUILDKIT_PROGRESS=plain docker
  build ...`). Codifies the user feedback: "build/run/exec/stop 一律
  走 .sh wrapper; 沒 wrapper 要詢問 user; user 沒明確同意一律禁止".
- New PreToolUse hook `.claude/hooks/check_tag_version_consistency.sh`
  blocks `git tag -a v*` / `git tag v*` (lightweight) /
  `git push <remote> v*` / `git push <remote> refs/tags/v*` when the
  repo root has a `.version` file whose content does not match the
  tag name. Closes the gap that allowed template v0.18.0 / v0.18.1
  to ship with `.version` still on `v0.17.0` — `make upgrade-check`
  in downstream repos kept reporting upgrade-available because the
  metadata was wrong. Skips deletes (`-d` / `:tag`), tag listing,
  `git push --tags` (bulk; out of scope), and downstream consumer
  repos that only have `template/.version` (their tags are
  independent of the consumed template version). 15 bats specs cover
  the full matrix. Refs issue #36 (Ask 1).
- New PreToolUse hook `.claude/hooks/remind_make_first_upgrade.sh`
  emits a non-blocking reminder when the agent runs
  `./template/upgrade.sh` directly while `Makefile.ci` declares an
  `upgrade:` target. Make wrapper internally calls the same .sh but
  also runs `init.sh` symlink resync + `main.yaml @tag` rewrite, so
  going through it lowers the chance of half-upgrades. Hook silent
  when no Makefile.ci, no `upgrade:` target, or the wrapper is
  already in use. 8 bats specs cover trigger paths + silence cases.
  Codifies CLAUDE.md「升級一律 make 優先」at the hook layer. Refs
  issue #36 (Ask 2).

### Documentation
- `CLAUDE.md` new section "Process discipline — slash command / skill
  優先於 ad-hoc 執行" — explicit rule that documented entry points
  (`.claude/commands/` + `.claude/skills/`) are the contract for
  multi-step mutating flows; ad-hoc execution is allowed only for
  trivial read-only checks. Lists the v0.18.0 / v0.18.1 release
  incident as the motivating case (`/release` was bypassed, the
  chore-PR step that bumps `.version` got skipped, hook layer had no
  fallback). Cross-links to the two new hooks above. Refs issue #36
  (Ask 2).

### Changed
- `.claude/scripts/batch-template-upgrade.sh` now self-prints a
  copy-pasteable next-step block at end of every real run:
  `wait-pr-ci-batch.sh <pairs> --check-filter ...` followed by
  `batch-pr-merge.sh <pairs>`, with the exact `<reponame>:<pr_num>`
  pairs captured from each successful `gh pr create`. Sessions that
  bypass `/batch-template-upgrade.md` and call the script directly
  now still see the productized waiter — fixes the v0.15.0 rollout
  regression where a session fell back to the old ad-hoc
  `/tmp/wait-batch-vX.Y.Z.sh` pattern (file didn't exist; only an
  error log left behind). 7 new bats specs cover arg validation
  (`--help` / missing version / missing why / unknown arg) plus
  three unit tests of `print_next_step_hint` (multi-pair / single
  pair / silent on empty).
- `remind_docker_for_lint.sh` wrapper list now configurable per repo
  via sibling `.claude/lint_wrappers.txt` (one substring pattern per
  line; blank / `#`-prefixed lines skipped). When the file is present
  it FULLY REPLACES the default list, not appends. Useful for
  downstream forks that wrap lint differently — coreSAM (#7) needs
  `make -C .claude` instead of this repo's `make -f Makefile.ci`.
  Default list also extended to include `make -C .claude/test`
  (already used in this repo for the test infra Makefile but missing
  from the previous hardcoded list). 5 new bats specs cover the
  default fallback + file override + comment/blank line skipping +
  missing `CLAUDE_PROJECT_DIR` defensive path; existing 7 specs
  remain. Addresses #7 (2).

### Documentation
- `CLAUDE.md` new section "Sandbox baseline (settings.local.json)" —
  explains the `sandbox.enabled` + `autoAllowBashIfSandboxed` +
  `filesystem.allowWrite` combination and what it lets the
  `permissions.allow` list shed. Tables out the per-key semantics and
  notes when sandbox isn't enough (parser fallback fires before
  sandbox eval). Onboarding aid for newcomers grappling with bloated
  allow lists; addresses #7 (1) (CoreSAM downstream port feedback).

### Added
- `.claude/scripts/wait-pr-ci-batch.sh` — multi-repo PR-scoped sibling
  of `wait-pr-ci.sh`, aggregating N PRs across N repos into one
  Monitor stream. Args: positional `<repo>:<pr>` pairs (short form
  auto-prefixed with `ycpss91255-docker/` via `--owner` default).
  Same output shape, exit codes, `--check-filter`, `--interval`,
  `--max-iterations` semantics as the single-repo flavour. Resolves
  the "spawn one Monitor per repo" guidance for N=15+ batches that
  produces noisy parallel notification streams. Closes #16.
- `.claude/scripts/check-claude-md-tree.sh` — CI lint that parses the
  `.claude/` tree listing in `CLAUDE.md` and diffs against the
  filesystem under `.claude/commands/`, `.claude/scripts/`,
  `.claude/hooks/`. Exits 1 on drift with `+` / `-` entry diff;
  exits 2 on usage / parse error. Honours folded subdirs
  (`└── test/` placeholder under `hooks/`) so they don't false
  positive. Wired into `.claude/test/Makefile` as a new `tree-check`
  target (also added to `check`) and into `.github/workflows/test.yaml`
  as a CI step. Background: PR #29 caught up 7 entries that drifted in
  one week of feature work; this lint prevents recurrence by failing
  the build instead of relying on memory or `/doc-sync`. 8 bats specs
  cover help / missing inputs / aligned / fs-drift / tree-drift /
  folded subdir handling / multi-dir drift.

### Changed
- `.claude/skills/wait-pr-ci/SKILL.md` documents the new third
  flavour (multi-repo batch). Replaces the previous "spawn one
  Monitor per repo in parallel" guidance with: N=2-3 use single-repo
  Monitors, N=4+ use `wait-pr-ci-batch.sh`.
- `.claude/commands/batch-template-upgrade.md` "After the script"
  section now points at `wait-pr-ci-batch.sh` for the wait step and
  `batch-pr-merge.sh` for the merge step (was an ad-hoc `gh pr merge`
  per-repo block — exactly the loop pattern the CLAUDE.md cross-repo
  batch-mutation rule rules out). Closes #17.

### Documentation
- Catch up `CLAUDE.md` `.claude/` directory tree drift (audit found 7
  entries added in past PRs but never synced into the tree listing):
  - `hooks/`: + `remind_no_chinese_in_git_artifacts.sh` (PR #20),
    + `remind_test_tools_smoke_sync.sh`
  - `scripts/`: + `batch-gitignore-fix.sh` (PR #21),
    + `batch-gitignore-add-line.sh` (PR #23),
    + `batch-pr-merge.sh`,
    + `check-template-versions.sh` (PR #18),
    + `fix-compose-copy-line.sh`
  No code change. Follow-up `.claude/scripts/check-claude-md-tree.sh`
  CI lint planned to prevent recurrence (drift accumulated ~7 entries
  in roughly one week of feature work).

### Changed
- `/issue-fix` now auto-merges PRs on CI green (matching `/pr.md` and
  `wait-pr-ci` skill defaults) instead of leaving them for human merge.
  Step 7 ALL_DONE handler now runs `gh pr merge --squash --delete-branch`
  + `git fetch` + `git worktree remove` inline; CI red still halts (no
  auto-merge, worktree left for inspection). The "Never auto-merge"
  note in the original `/issue-fix` was inconsistent with the rest of
  the project's PR workflow — `/pr.md` step 6 and the `wait-pr-ci`
  skill's "Pairing with merge" section both auto-merge on `ALL_DONE`.
  Branch protection (`enforce_admins=true` + `required_status_checks`
  strict) still applies, so `gh pr merge` refuses if CI didn't really
  pass or the branch is stale.

### Added
- New helper script `.claude/scripts/run-bats-in-compose.sh` — wraps
  `docker compose run --entrypoint bash <service> -c '<inline>'` so
  Claude's bash AST parser sees only atomic flags (`--service`,
  `--suite`, `--grep`, `--tail`, `--head`, `--compose-file`), not a
  quoted shell body. Avoids the "Unhandled node type: string" fallback
  that fires on `docker compose ... bash -c '<long string>'` patterns
  even when `Bash(docker:*)` is allow-listed (the parser fallback is
  pre-allowlist). Default behaviour: `--suite all`, `--grep '^not ok'`
  (fail-only), `--tail 25`. Composable: `--suite <kind>` accepts
  `unit` / `integration` / `all` / arbitrary path under `/source`,
  `--grep ''` disables filter for full output. 14 bats specs cover
  flag parsing, suite resolution, grep-pipe composition, env
  propagation, --head / --tail mutual exclusion, and quoting-injection
  rejection.

### Changed
- `/issue-fix` second arg now accepts `all` (or omitted) for batch mode —
  iterates every open issue on `<repo>` serially, oldest first (FIFO),
  pre-filtering out issues with open linked PRs / `wontfix` / `invalid` /
  `duplicate` / `do-not-merge` / `discussion` / `question` labels and
  any issue already carrying a `Reviewed by /issue-fix automation`
  comment. New `--limit N` flag truncates the post-filter list. Each
  surviving issue runs the full single-issue flow (reasonableness check
  → reject + comment, or worktree + PR + CI wait); the batch stops on
  the first CI red but continues through reject / scope-exceeded
  outcomes per issue. Ends with a Traditional Chinese summary block
  listing accepted / rejected / scope-exceeded / skipped counts plus
  the stop reason. Single-issue mode (when `<issue_num>` is a positive
  integer) preserves the original behaviour.

### Added
- New PreToolUse Bash hook `.claude/hooks/remind_readme_on_core_script.sh` —
  fires before `git commit` when staged files include template's core
  install/upgrade scripts (`template/upgrade.sh`, `template/init.sh`,
  `template/upgrade-check.sh`, `template/script/docker/setup.sh`, or the
  same paths from a template-internal session without the `template/`
  prefix) but no `README*.md` is in the same commit. Advisory only —
  emits a `systemMessage` reminder, does not block. Closes the gap where
  README's "Upgrading" / "Configuration" sections drift from upgrade.sh
  internals (e.g. implicit-downgrade refusal, `_warn_config_drift`,
  config/ preservation all shipped without README mention). Skips
  `--amend` / `--allow-empty`. 13 bats specs cover non-commit / amend /
  no-stage / readme-only / build.sh / each core script path / both
  prefixes / core+readme together / `git -C <path>`.
- New slash command `/issue-fix <repo> <issue_num> [--dry-run]` —
  delegates auto-fixing one open `ycpss91255-docker/<repo>` issue to the
  agent when scope is reasonable; rejects (with one explanatory comment
  on the issue) when not. Reasonableness gate covers: thin body, pure
  question, architectural decision, cross-repo coordinated change,
  destructive migration, >200-line diff estimate, conflicting reports.
  On accept: opens a worktree per the worktree workflow, writes a
  regression test first (TDD), implements the minimal fix, runs the
  repo's standard Docker-based test runner, opens a PR with
  `Closes #<num>`, then waits for CI to settle via `wait-pr-ci` skill
  (B2 — block until green). Never auto-merges. If diff exceeds 200
  lines mid-implementation, comments on the issue and leaves the
  worktree for human inspection. Per-repo `--check-filter` for
  `wait-pr-ci.sh` documented in the command (template / multi_run
  default; claude-workspace `bats + shellcheck + hadolint`; container
  repos `call-docker-build / docker-build`). Pairs with the
  read-only `/issue-check`.
- `CLAUDE.md` new section "git worktree 用法（強制）": for any new
  branch / WIP / chore PR on any of the 18 git repos, use
  `git worktree add <workspace>/worktree/<repo>-<N> -b <branch> main`.
  Standard location `<workspace>/worktree/` is already gitignored at
  workspace level. Existing 18 main checkouts (workspace + 17
  downstream + template) stay fixed at origin/main — no branches, no
  WIP commits, no dirty working tree. Multiple worktrees can coexist
  for parallel sessions on the same repo. Cross-repo batch scripts
  (`batch-template-upgrade.sh` etc.) are exempt — they manage their
  own fetch / branch flow internally. On a fresh machine without
  `<workspace>/worktree/`, Claude must ask the user where to place
  worktrees rather than guess. Closes part of #22.
- New helper script `.claude/scripts/batch-gitignore-add-line.sh` —
  generic sister of `batch-gitignore-fix.sh` that **appends** an
  arbitrary line to each downstream `.gitignore` if not already
  present. Mirrors the `--why-file` / `--why` / `--only` / `--skip` /
  `--dry-run` / `--continue-on-error` shape. Idempotent (skip if line
  already exists). 7 bats specs cover help / required-arg /
  unknown-arg / dry-run / scope filter / branch-name slugification.
  First use case: add `CLAUDE.md` to each downstream `.gitignore` so
  per-repo `<repo>/CLAUDE.md → ../<n>/CLAUDE.md` symlinks (issue #22)
  don't leak into git status.

### Changed
- Slash commands made cwd-aware so they degrade gracefully when invoked
  from per-repo sessions (e.g. `cd template && claude`) instead of the
  workspace root:
  - `/doc-sync` default path changed from hardcoded
    `/home/yunchien/workspace/docker` to `${CLAUDE_PROJECT_DIR}`. From
    workspace cwd it covers all sub-repos as before; from per-repo cwd
    it scopes to that single repo. Removes a user-specific path that
    would have failed on any other machine.
  - `/pr` step 7 (template-merge fanout to 17 downstream repos) now
    explicitly notes "Scope: workspace cwd only" and points at
    `/batch-template-upgrade` for the per-repo session case. Manual
    fanout block kept for reference but `(cd ... && cmd)` subshell
    replaces the bare `cd` to avoid session cwd pollution.
  - `/batch-pr`, `/new-repo`, `/batch-template-upgrade` each gain a
    `Scope: workspace cwd only` block at the top — these commands
    iterate `${CLAUDE_PROJECT_DIR}/<category>/<repo>` paths and only
    work from the docker workspace root. Per-repo session use should
    fail loudly with a clear redirect to `/pr` (single-repo) or
    workspace re-entry.
- `check_no_emoji.sh` skip list extended to mirror
  `check_no_ai_attribution.sh`: meta-doc files (`CLAUDE.md`,
  `.claude/commands/*.md`, `.claude/skills/*/SKILL.md`,
  `doc/test/TEST.md`, `doc/changelog/CHANGELOG.md`) that legitimately
  quote the rules they enforce are no longer flagged. Surfaced when
  doc-sync.md `🤖 Generated` (a forbidden-pattern reference, not a
  violation) caused the hook to fire on every edit. 2 new bats specs.
- `release` slash command rewritten to match the actual
  ycpss91255-docker repo convention. Previously the skill said "tag and
  push" only; the real flow used by v0.12.0 → v0.12.3 is **branch →
  bump `.version` + CHANGELOG → chore PR → CI → merge → annotated tag
  on the merge commit → push tag → wait tag-triggered workflows**. The
  new doc has 9 numbered steps, RC failure handling (never re-tag the
  same RC), and points at `/batch-template-upgrade` for downstream
  propagation. PATCH releases (vX.Y.PATCH) skip RC; MINOR / MAJOR keep
  the RC dance via `-rcN` suffix on the same chore-PR pipeline.
- `CLAUDE.md` Bash parser-limit cheat sheet: new row covering
  `docker run ... bash -c '<長 inline 字串>'` (multi-line shell logic
  wrapped in quotes triggers `Unhandled node type: string` regardless
  of allowlist). Canonical replacement: write the body to `/tmp/<name>.sh`
  via the Write tool, then `docker run -v "$PWD":/source ... bash
  /source/<rel-path>/<name>.sh`. Generalises the existing rule for
  `gh ... --body "$(cat)"` — long quoted bodies always extract to
  files, never inline.
- `CLAUDE.md` `gh ... --body "$(cat path)"` row strengthened to also
  cover `gh ... --body-file - <<'EOF'` (heredoc-into-stdin), which
  trips either `Unhandled node type: string` or `Contains zsh =cmd
  equals expansion` depending on body content. Canonical fix is the
  same: write body to `/tmp/<name>.md` via Write, then
  `gh ... --body-file /tmp/<name>.md`. The single-row update keeps the
  cheat sheet consolidated rather than splitting into two near-duplicate
  entries.
- `CLAUDE.md` cheat sheet adds a row for `gh pr merge N --repo X` from
  a foreign cwd. Claude Code's built-in state-changing safety check
  fires regardless of allowlist or `autoAllowBashIfSandboxed` — this is
  intentional, not a parser limit, and not bypassable via `-R X` short
  form or `(cd path && ...)` subshell (the `docker` monorepo carries
  `ycpss91255-docker/template` only as a git subtree, not a separate
  checkout, so there's no template-rooted cwd to cd into). Captured to
  CLAUDE.md so Claude expects the prompt and accepts it instead of
  retrying alternative shapes.
- `remind_use_body_file.sh` hook extended to also detect
  `gh ... --body-file -` (stdin variant, typically `--body-file - <<EOF`).
  Previously the hook only caught `--body|--comment "$(cat path)"`,
  letting the heredoc-stdin variant slip through and re-prompt the
  user (observed during the v0.12.2 / v0.12.3 release cycle where
  release-PR creation kept hitting `Unhandled node type: string` or
  `Contains zsh =cmd equals expansion` despite the existing rule).
  Detection regex looks for `--body-file -` terminated by whitespace,
  end-of-string, or shell operator; silent on `--body-file <real-path>`.
  3 new bats specs (FIRE on heredoc, FIRE on bare `-`, SILENT on a
  path containing `-`).

### Added
- New blocking PreToolUse hook
  `remind_no_chinese_in_git_artifacts.sh` enforces English-only commit
  messages, PR + issue titles, bodies, and comments. Detects CJK
  Unified Ideographs (U+4E00-9FFF), CJK Ext-A (U+3400-4DBF), CJK
  Symbols & Punctuation (U+3000-303F: corner brackets, fullstop,
  enumeration comma), and Halfwidth / Fullwidth forms (U+FF00-FFEF:
  fullwidth comma, exclamation, question mark, fullwidth digits and
  letters). En-dash / em-dash / smart quotes / ellipsis stay allowed
  (English typography uses these). Triggers on `git commit -m / -F`,
  `gh pr create | edit | comment` with `--title / --body / --body-file`,
  `gh issue create | edit | close | comment` with the same flags +
  `--comment`. `--body-file` referenced paths are read and scanned;
  README\*.md and i18n / locale files (`*.zh-TW.md`, `*.zh-CN.md`,
  `*.ja.md`, `*.ko.md`, `*i18n*`, `*.po*`, `*.mo`) are exempt.
  Returns `permissionDecision: "deny"` rather than a non-blocking
  systemMessage so the offending command never reaches GitHub —
  no `git commit --amend` / `gh pr edit` cleanup needed afterwards.
  11 bats specs cover ideograph + fullwidth punctuation + fullwidth
  digit + CJK in `--body-file` (with exempt-path skip) + English
  typography passthrough + non-target commands.
- New PostToolUse hook `remind_test_tools_smoke_sync.sh` fires on Edit
  / Write to `dockerfile/Dockerfile.test-tools` and prints the alpine
  packages on the final-stage `apk add --no-cache` line alongside the
  tools verified by the sibling `release-test-tools.yaml` smoke step,
  so a missing `--version` / `--help` check shows up as a visible
  diff before commit. Surfaced as a recurring pain during #168: each
  Dockerfile rebase that added a new package (parallel → git →
  git-subtree → grep / coreutils) needed a matching smoke-step row,
  and 3 of 4 were caught reactively (CI fail) instead of proactively.
  The hook does NOT enforce a strict 1:1 mapping — packages without a
  single probe binary (ca-certificates, coreutils) are intentionally
  left for human judgment. Includes 7 bats specs covering fire /
  silent / final-stage-only parsing paths; registered in
  `.claude/settings.json` PostToolUse next to `remind_tdd_categories.sh`.
- New helper script `.claude/scripts/batch-gitignore-fix.sh` — opens
  one chore PR per downstream repo (17 + template) to replace
  `.claude/` with `.claude` in each repo's `.gitignore`. The trailing
  slash form only matches a real directory; the docker monorepo
  creates `<repo>/.claude` as a relative symlink to the workspace
  `.claude/` for per-repo Claude sessions, which leaks into
  `git status` as `?? .claude` under the old pattern. Mirrors
  `batch-template-upgrade.sh` shape (`--why-file` / `--why` /
  `--only` / `--skip` / `--dry-run` / `--continue-on-error`),
  idempotent (skip if `.claude/` line already absent), no code or
  build impact in any downstream repo (gitignore-only). 5 bats specs
  (--help / required-arg / unknown-arg / dry-run / --only filter).
- New helper script `.claude/scripts/check-template-versions.sh` —
  read-only HTTPS fetch of `template/.version` from main for every
  downstream repo (17 repos in `DEFAULT_REPOS`, mirroring
  `batch-template-upgrade.sh`). Used during release verification to
  confirm `/batch-template-upgrade <vX.Y.Z>` PRs have all merged.
  Replaces the ad-hoc `for repo in ...; do curl ...; done` pattern that
  trips Claude Code's bash AST parser (`Unhandled node type: string`).
  Supports `--only` / `--skip` filters and `--expect <vX.Y.Z>` (exit 1
  on any mismatch). 7 bats specs stub `curl` via PATH for offline
  testing; registered in `.claude/settings.local.json` allow list and
  documented in `doc/test/TEST.md`.
- Hook test infrastructure relocated to `.claude/test/` so the workspace
  root is no longer polluted with Claude-only files. `Dockerfile.test`
  → `.claude/test/Dockerfile`; root `Makefile` → `.claude/test/Makefile`.
  Build context is repo root (so `COPY .claude/hooks/` paths still
  resolve); invocation becomes `make -C .claude/test <target>`. CI
  workflow `.github/workflows/test.yaml` gains a job-level
  `working-directory: .claude/test`. Reason: `Dockerfile.test` is purely
  meta-repo test infra (only COPYs `.claude/hooks/` + `.claude/scripts/`,
  zero overlap with downstream repo Dockerfiles), so it belongs inside
  `.claude/`. `.hadolint.yaml` comment + README + CLAUDE.md tree +
  TEST.md commands all updated to match.

### Added
- Three new hooks:
  - `check_changelog_drift.sh` (PreToolUse Bash) — flags `git commit`
    when staged code/config files are not accompanied by a
    `doc/changelog/CHANGELOG.md` update.
  - `check_no_ai_attribution.sh` (PostToolUse Edit/Write) — scans
    touched files for `Co-Authored-By: Claude` / `Generated with Claude
    Code` boilerplate.
  - `remind_no_ai_attribution.sh` (PreToolUse Bash) — flags inline
    attribution markers embedded in `git commit -m` / `gh pr create
    --body` / similar commands.
- Hook test infrastructure under `.claude/hooks/test/`:
  - `lib/test_helper.bash` shared helpers (bats-support / bats-assert,
    `mktemp_repo`, `assert_message_contains`, `assert_silent`).
  - 53 smoke tests across 10 specs (one per hook).
  - 4 integration tests in `chain_spec.bats` covering multi-hook
    scenarios.
- `Dockerfile.test` (bats 1.11 + shellcheck on Alpine) and `Makefile`
  with `build` / `test` / `lint` / `hadolint` / `check` targets — all
  validation runs inside Docker per CLAUDE.md「驗證一律走 Docker」.
- `.github/workflows/test.yaml` — GitHub Actions CI running
  shellcheck + Hadolint + bats on every PR and push to `main`.
- `doc/test/TEST.md` test catalog (single source of truth) and this
  CHANGELOG.
- `/issue-check` slash command (`.claude/commands/issue-check.md`):
  scans open issues across the `ycpss91255-docker` org and groups them
  by actionability (進行中 / 可 merge / 卡住 / 停滯 / 待分類 / 孤兒).
  Read-only; output in Traditional Chinese.
- `/batch-template-upgrade` slash command + implementation script and
  PR body template:
  - `.claude/commands/batch-template-upgrade.md` — workflow doc.
  - `.claude/scripts/batch-template-upgrade.sh` — parameterized impl
    (`<version>` + `--why-file` / `--why` / `--issue` / `--dry-run` /
    `--only` / `--skip` / `--continue-on-error`). Iterates 17
    hardcoded `DEFAULT_REPOS`, fetches `main` via HTTPS, runs
    `./template/upgrade.sh + ./template/init.sh`, opens one PR per
    repo. Designed for the main session (subagent sandbox blocks
    `git push`).
  - `.claude/scripts/batch-template-pr-body.template.md` — PR body
    template rendered via `envsubst` with `${VERSION}` / `${WHY}` /
    `${ISSUE_LINE}`.

### Changed
- `check_test_md_drift.sh` now resolves drift in pure bash; the
  previous gawk-only `match($0, /re/, arr)` 3-arg form silently
  mis-ran under mawk / POSIX awk.
- `check_no_emoji.sh`, `check_no_coverage_excl.sh`,
  `check_no_ai_attribution.sh` skip `.claude/hooks/test/*` so test
  fixtures can legitimately contain the forbidden patterns.
- `check_no_ai_attribution.sh` additionally skips meta-doc files
  (`CLAUDE.md`, `.claude/commands/*.md`, `.claude/skills/*/SKILL.md`,
  `doc/test/TEST.md`, `doc/changelog/CHANGELOG.md`) that legitimately
  quote the rules they enforce.
- `.claude/commands/*.md`: replaced hard-coded
  `/home/yunchien/Desktop/docker` paths with `${CLAUDE_PROJECT_DIR}`
  for cross-machine portability; `pr.md` no longer recommends adding
  AI attribution lines (contradicted CLAUDE.md).
- `CLAUDE.md`: git-config example uses `<your-name>` /
  `<your-email>` placeholders; the `.github/` directory in the
  workspace tree is now `org-profile/` (local checkout) so
  claude-workspace can own `.github/workflows/` for its own CI.
- Two PreToolUse Bash hooks to nudge Claude away from
  parser-failing command shapes:
  - `remind_no_heredoc_redirect.sh` — fires on `cat <<EOF > path`
    redirects (which trigger Claude Code's `Unhandled node type:
    file_redirect` warning); reminds to use the Write tool instead.
  - `remind_use_body_file.sh` — fires on `gh ... --body|--comment
    "$(cat path)"` (which triggers `Unhandled node type: string`);
    reminds to use `--body-file <path>` (gh CLI native).
- 16 new smoke tests covering the two hooks (10 + 6), bumping the
  total from 57 to 73 (69 smoke + 4 integration). The heredoc hook
  anchors `cat` to a command-start position (`^` or after `;|&|`)
  so descriptions of the pattern in quoted strings (e.g. a git
  commit message documenting the rule) do not trigger.
- `CLAUDE.md` 「## Bash 命令寫法的 parser 限制」 section: catalogs
  six command patterns that fall back to a user prompt regardless of
  allowlist / `autoAllowBashIfSandboxed` (heredoc-to-file, `$(cat
  path)`, complex for-loops with `${var%:*}`, Monitor inline bodies,
  `cd path && git ...`, `[[ a != b ]]` inside Monitor) along with
  their canonical replacements.
- `CLAUDE.md` 「## 主動優化建議」 adds a "任務結束時主動列 skill 化候選"
  sub-section: at PR-merge / task wrap-up, surface ad-hoc scripts in
  `/tmp` or repeated complex bash pipelines as skill candidates so they
  don't get lost or rewritten next time.
- `wait-pr-ci` SKILL.md: example loop uses `case` patterns instead of
  `[[ a != b ]]`. The Monitor tool's eval wrapper escapes `!` to `\!`
  ("history-expansion guard"), which broke the `!=` comparison with
  `conditional binary operator expected`. `set +H` did not save it.
- `wait-pr-ci` skill: Monitor body extracted into permanent scripts
  so the inline loop disappears. Two siblings sharing the same CLI
  shape (`--repo`, `--check-filter`, `--interval`,
  `--max-iterations`):
  - `.claude/scripts/wait-pr-ci.sh` — PR-scoped (`gh pr view --json
    statusCheckRollup`); `--prs <CSV>`; supports template /
    container / org-profile check filters. Closes #4.
  - `.claude/scripts/wait-tag-ci.sh` — tag/branch-scoped (`gh run
    list --branch <ref>`); `--branch <tag-or-branch>`,
    `--limit <N>`. Used after `git push origin <tag>` to wait on
    `on: push: tags:` workflows.
  SKILL.md reframed to cover both flavours; documents per-repo
  filter table, anti-patterns, and merge/release pairing.
- 21 new smoke tests across `wait_pr_ci_spec.bats` (11) and
  `wait_tag_ci_spec.bats` (10), mocking `gh` via PATH stub.
  Total bumps from 73 → 94 (90 smoke + 4 integration).
  `Dockerfile.test` now COPYs `.claude/scripts/` and `make lint`
  extends shellcheck to `.claude/scripts/*.sh`.
- `CLAUDE.md` 「## 跨 repo 批次 mutation 規範」 new section: any
  state change (commit/push/`git reset --hard`/`git branch -D`/issue
  or PR close/merge) over ≥2 repos must go through a documented
  slash command or `.claude/scripts/` script — no ad-hoc
  for-loops. Reason: a 15-iteration loop fires the user-confirm
  prompt 15 times → yes-fatigue → effectively bypasses the `ask`
  rules. Read-only loops (e.g. `gh pr view --json state` across
  repos) remain allowed.
- `CLAUDE.md` Bash parser-limit cheat sheet: Monitor row now points
  to both `wait-pr-ci.sh` (PR) and `wait-tag-ci.sh` (tag/branch)
  as the canonical replacements for inline Monitor poll loops.
- `auto_allow_rm_in_workspace.sh` (PreToolUse Bash) — first hook
  using `hookSpecificOutput.permissionDecision` instead of a
  `systemMessage` reminder. Auto-allows `rm` invocations whose
  path arguments are all confined to `${CLAUDE_PROJECT_DIR}` or
  `/tmp`; anything outside falls through silently so the existing
  `Bash(rm:*)` ask rule still catches `rm /etc/passwd` etc.
  Static-resolution guards: rejects `$` / backtick / `~` / `..`
  expansions, command chains (`&&` / `||` / `;` / `|`), and
  outside-zone absolute paths. Eliminates yes-fatigue on routine
  workspace cleanups while keeping the catch-all safety net.
- 18 smoke tests in `test/smoke/auto_allow_rm_in_workspace_spec.bats`
  covering ALLOW / SILENT decisions across relative paths, /tmp,
  workspace absolutes, flags, `--` separator, expansion guards,
  traversal, chains, pipes, and defensive fallbacks.
  `test_helper.bash` gains `assert_permission_decision <expected>`
  for asserting `hookSpecificOutput.permissionDecision`. TEST.md
  Smoke-spec preamble reframed for three behaviours
  (FIRE / ALLOW / SILENT). Total: 94 → 112.
- `CLAUDE.md` Bash parser-limit cheat sheet: new row covering
  `until ... $(cat <pidfile>) ...; do sleep N; done` background-task
  poll loops (triggers `Contains command_substitution`). Canonical
  replacement is the `Bash` tool's `run_in_background` parameter
  (runtime auto-notifies on completion); GitHub CI keeps using
  `wait-pr-ci.sh` / `wait-tag-ci.sh`. Avoids yes-fatigue when
  Claude waits on a long-running local process it just spawned.
