# Tests

Single source of truth for test counts and locations. Hooks
(`check_test_md_drift.sh`) compare per-file `@test` counts against the
numbers in this document on every Edit/Write of `*.bats` or `TEST.md`.

All tests run inside Docker via the `.claude/test/Dockerfile` image
(test infra lives under `.claude/test/`):

```bash
make -C .claude/test build       # build the test image (docker_harness-test:local)
make -C .claude/test test        # run all bats specs
make -C .claude/test lint        # shellcheck on all hook + helper scripts
make -C .claude/test hadolint    # hadolint on .claude/test/Dockerfile
make -C .claude/test check       # lint + hadolint + test (full CI gate)
```

Total: **1047 tests** (1044 smoke + 3 integration) plus shellcheck (42 hook
scripts + 34 helper scripts) plus Hadolint (`.claude/test/Dockerfile`)
plus a CONTEXT.md `.claude/` tree audit (`make tree-check` —
`.claude/scripts/check-claude-md-tree.sh`; pre-#127 audited
CLAUDE.md) plus a CLAUDE.md ceiling audit (`make ceiling-check`
— `.claude/scripts/check-claude-md-ceiling.sh`; defaults 240
lines / 20 `^##` sections) plus a log-helper-usage audit
(`make log-helper-check` —
`.claude/scripts/check-log-helper-usage.sh`; enforces lib/log.sh
adoption in `.claude/scripts/*.sh`, refs #148 M5).

## 4-category coverage

Per CONTEXT.md §11 (TDD 4-category matrix; pre-#127 lived in CLAUDE.md):

| # | Category | Where | What it covers |
|---|----------|-------|----------------|
| 1 | Smoke | `test/smoke/*_spec.bats` | Each hook fires on its trigger and stays silent otherwise |
| 2 | Unit | n/a (hooks are linear single-function scripts) | Smoke covers what unit would |
| 3 | Integration | `test/integration/chain_spec.bats` | Multi-hook scenarios where the same tool input drives several hooks |
| 4 | Lint | `make -C .claude/test lint` (shellcheck) + `make -C .claude/test hadolint` | All `.sh` hooks + helper scripts pass shellcheck; `.claude/test/Dockerfile` passes Hadolint |

## Smoke specs

Every `.bats` file targets a single hook (or a script under
`.claude/scripts/`). Each test pipes a sample JSON tool-input on
stdin and asserts one of three behaviours:

- **FIRE** — emits JSON with `.systemMessage` (reminder hooks like
  `remind_*.sh` / `check_*.sh`). Use `assert_message_contains`.
- **ALLOW** — emits JSON with `.hookSpecificOutput.permissionDecision`
  (programmatic auto-allow hooks like
  `auto_allow_rm_in_workspace.sh`). Use `assert_permission_decision`.
- **SILENT** — exits 0 with no stdout (no action taken). Use
  `assert_silent`.

### test/smoke/auto_allow_rm_in_workspace_spec.bats (18)
| Test | Scenario |
|------|----------|
| allows rm <relative file> (workspace cwd assumed) | relative path → ALLOW |
| allows rm subdir/file.txt | nested relative → ALLOW |
| allows rm /tmp/foo.sh | absolute under /tmp → ALLOW |
| allows rm -rf /tmp/dir | flag + /tmp path → ALLOW |
| allows rm /home/yunchien/workspace/docker/foo.txt (under workspace) | absolute under workspace → ALLOW |
| allows rm -- --weird-name (after -- separator) | `--` separator handling |
| silent on rm /etc/passwd (outside workspace) | absolute outside → SILENT (falls through to ask) |
| silent on rm /usr/bin/foo (outside workspace) | absolute outside → SILENT |
| silent on rm /home/yunchien/.bashrc (home outside workspace) | home dotfile → SILENT |
| silent on rm ~/.ssh/id_rsa (~ rejected) | tilde-expansion guard |
| silent on rm $HOME/.bashrc ($ rejected) | shell-var guard |
| silent on rm \`pwd\`/file (backtick rejected) | command-substitution guard |
| silent on rm ../../etc/passwd (.. traversal rejected) | path-traversal guard |
| silent on rm /tmp/foo && rm /etc/passwd (chain rejected) | command-chain guard |
| silent on rm /tmp/foo \| xargs (pipe rejected) | pipe guard |
| silent on non-rm command (ls -la) | matcher narrowed to rm |
| silent on rmdir (different command) | exact `rm` match, not prefix |
| silent on empty CLAUDE_PROJECT_DIR (defensive) | refuses to act without anchor |

### test/smoke/auto_allow_touch_ack_spec.bats (14)
| Test | Scenario |
|------|----------|
| allows touch /tmp/claude-checkpoint-foo.ack | minimal ack path → ALLOW |
| allows touch /tmp/claude-checkpoint-make-upgrade-sess123-abc.ack (slug-session-hash shape) | full slug-session-hash naming → ALLOW |
| allows touch $TMPDIR/claude-checkpoint-bar.ack (literal $TMPDIR token) | literal $TMPDIR (unexpanded in helper output) → ALLOW |
| allows touch -- /tmp/claude-checkpoint-baz.ack (after -- separator) | `--` separator handling |
| silent on touch /tmp/other.txt (not a checkpoint ack) | non-ack /tmp file → SILENT |
| silent on touch /etc/shadow (outside TMPDIR + /tmp) | absolute outside → SILENT |
| silent on touch /tmp/claude-checkpoint-foo.md (.md not .ack) | wrong extension → SILENT |
| silent on touch /tmp/claude-checkpoint-.ack (empty slug rejected) | regex requires ≥1 slug char |
| silent on non-touch command (ls /tmp/claude-checkpoint-foo.ack) | matcher narrowed to touch |
| silent on touch /tmp/../etc/claude-checkpoint-x.ack (.. traversal) | path-traversal guard |
| silent on touch /tmp/claude-checkpoint-a.ack && rm -rf / (command chain) | command-chain guard |
| silent on touch /tmp/claude-checkpoint-a.ack /tmp/other.txt (multi-arg with non-ack) | multi-arg guard |
| silent on touch /tmp/CLAUDE-CHECKPOINT-foo.ack (case-sensitive prefix) | regex is case-sensitive |
| silent on empty command | empty input guard |

### test/smoke/check_changelog_drift_spec.bats (6)
| Test | Scenario |
|------|----------|
| fires when code staged without CHANGELOG | code-only staged, no `doc/changelog/CHANGELOG.md` in commit → FIRE |
| silent when code AND CHANGELOG staged together | both staged → SILENT |
| silent when only docs staged | only `*.md` staged → SILENT |
| silent on --amend | `--amend` skips the rule → SILENT |
| silent in repo without doc/changelog/CHANGELOG.md (rule N/A) | rule does not apply → SILENT |
| resolves repo via cd subdir && git commit | `cd <repo> && git commit` parses correct repo → FIRE |

### test/smoke/remind_readme_on_core_script_spec.bats (13)
| Test | Scenario |
|------|----------|
| non-git-commit command is silent | `ls -la` → SILENT |
| git status is silent (not a commit) | `git status` → SILENT |
| git commit --amend is silent | `--amend` skips the rule → SILENT |
| git commit with no staged files is silent | empty index → SILENT |
| git commit with only README staged is silent | only `README.md` staged → SILENT |
| git commit with build.sh (non-core script) is silent | `build.sh` is not a core install/upgrade script → SILENT |
| git commit with .base/upgrade.sh and no README fires | core script + no README → FIRE |
| git commit with .base/init.sh and no README fires | core script + no README → FIRE |
| git commit with .base/script/docker/setup.sh and no README fires | core script + no README → FIRE |
| git commit with upgrade.sh (template-internal session, no prefix) fires | path without `.base/` prefix still matches → FIRE |
| git commit with core script + README is silent | both staged → SILENT |
| git commit with core script + translated README is silent | `README.zh-TW.md` counts → SILENT |
| git -C <path> commit resolves work dir from -C | parses `-C <repo>` to find correct repo → FIRE |

### test/smoke/check_no_ai_attribution_spec.bats (4)
| Test | Scenario |
|------|----------|
| fires on Co-Authored-By: Claude | content has `Co-Authored-By: Claude` → FIRE |
| fires on Generated with [Claude Code] | content has bracketed marker → FIRE |
| fires on Generated with Claude Code (no brackets) | content has plain marker → FIRE |
| silent on clean file | no markers → SILENT |

### test/smoke/check_no_coverage_excl_spec.bats (5)
| Test | Scenario |
|------|----------|
| fires on LCOV_EXCL_LINE | inline comment → FIRE |
| fires on LCOV_EXCL_START / STOP block | block markers → FIRE |
| fires on kcov-excl | kcov marker → FIRE |
| silent on clean file | no markers → SILENT |
| silent on .md file (skip) | `.md` is skipped by hook → SILENT |

### test/smoke/check_no_emoji_spec.bats (6)
| Test | Scenario |
|------|----------|
| fires when file contains emoji | emoji codepoint present → FIRE |
| silent on clean ASCII file | no emoji → SILENT |
| silent when file does not exist | file path missing → SILENT |
| silent when file is binary | binary file detected → SILENT |
| silent on meta-doc CLAUDE.md (legitimate emoji quoting) | rule-describing CLAUDE.md → SILENT |
| silent on .claude/commands/*.md meta-doc (rule description) | command markdown → SILENT |

### test/smoke/test_helper_stanzas_spec.bats (2)

Covers the `write_bats_stanzas <file> <count>` helper in
`test_helper.bash` (refs #166). The helper writes a `.bats` fixture
with `count` trivial `@test` stanzas via `printf` (never a heredoc),
sidestepping the bats preprocessor trap where literal `@test` at
column 0 inside a `<<'EOF'` heredoc is rewritten before bash sees it,
silently truncating the fixture.

| Test | Scenario |
|------|----------|
| write_bats_stanzas writes count real @test stanzas + shebang | core: 3 stanzas + shebang, grep-able |
| write_bats_stanzas count=0 yields shebang only, zero @test | edge: empty fixture |

### test/smoke/check_test_md_drift_spec.bats (15)

The regex parsing repo-local + `.base/test/` headings is shared:
`^### ((\.base/)?test/<path>.(bats|py)) (<N>)`. The optional `.base/`
prefix (added refs #156) lets downstream repos pin counts on tests
vendored via the `.base/` subtree -- otherwise a base subtree pull
that lands new `@test` stanzas drifts TEST.md silently. Counting is
extension-switched: `.bats` -> `^@test` stanzas, `.py` -> `def test_`
function definitions (top-level + class methods, refs #198 -- pytest
parity; the count tracks def-functions not collected cases, so
`parametrize` does not inflate it).

| Test | Scenario |
|------|----------|
| fires when TEST.md count > actual @test count | TEST.md claims more → FIRE |
| fires when TEST.md count < actual @test count | TEST.md claims fewer → FIRE |
| silent when counts match | counts equal → SILENT |
| fires when TEST.md lists missing bats file | bats file missing → FIRE |
| silent when edited file is not .bats or TEST.md | not a tracked file type → SILENT |
| fires when .base/test/smoke/*.bats count drifts (post base subtree upgrade) | subtree-vendored bats drifted → FIRE |
| silent when .base/test/smoke/*.bats count matches | subtree counts match → SILENT |
| fires when .base/test/smoke/*.bats heading lists missing file | subtree path in TEST.md but file absent → FIRE |
| repo-local and .base/ entries both checked in same TEST.md | mixed headings, one drifts → FIRE on the drifted one |
| fires when a pytest file's def test_ count drifts from TEST.md | pytest def-count drift → FIRE (issue #198) |
| silent when pytest def test_ count matches TEST.md | pytest counts match → SILENT |
| counts class-method pytest tests (indented def test_) | class-based pytest counted |
| fires when TEST.md lists a missing pytest file | pytest file missing → FIRE |
| test_ prefix pytest file (not just _test suffix) triggers the check | both discovery patterns fire |
| silent when edited file is a non-test .py (src module) | non-test .py → SILENT |

### test/smoke/check_readme_framework_spec.bats (20)
| Test | Scenario |
|------|----------|
| silent on a fully aligned English README | all 6 checks pass + 3 translations also aligned → SILENT |
| [1] fires on missing CI badge | English README without `actions/workflows/main.yaml/badge.svg` → FIRE |
| [2] fires on missing 4-language link | no `**[English](README.md)**` → FIRE |
| [3] fires when TL;DR is a blockquote | `> **TL;DR**` legacy quote → FIRE (must be `## TL;DR` H2) |
| [4] fires on stale .base/build.sh symlink target | `build.sh -> .base/build.sh` row → FIRE (canonical: `.base/script/docker/build.sh`) |
| [5] fires on .template_version reference | obsolete root version-pin file mentioned → FIRE (canonical: `.base/.version` since v0.16.0) |
| [6] fires on missing TEST.md link | no `(doc/test/TEST.md)` anywhere → FIRE |
| [drift] fires when a translation has no CI badge while English does | zh-TW empty while English has badge → FIRE |
| [drift] fires when a translation file is missing entirely | doc/README.ja.md missing → FIRE |
| checks a translation file directly with [zh-TW] label | edit doc/README.zh-TW.md, drift → message prefixed `[zh-TW]` |
| silent when editing .base/README.md (the framework reference itself) | path under `.base/` → SILENT (skipped) |
| silent when editing archive/<repo>/README.md (read-only archive) | path under `archive/` → SILENT (skipped) |
| silent when editing a non-README file | unrelated path → SILENT |
| silent on multi_run/README.md when fully aligned | multi_run path with all 4 languages aligned → SILENT |
| [7] silent when every tree path exists on disk (positive control) | Directory Structure tree where every leaf file/dir is materialized → SILENT (refs #65) |
| [7] fires when tree path does not exist on disk (the #65 drift) | flat-layout README after files were moved into a nested subdir → FIRE per stale path |
| [7] ignores ellipsis and pure tree-art lines | tree lines `│`, `├── ...`, `└── ...` → SILENT (no false positives) |
| [7] symlink notation 'build.sh -> .base/...' checks the link not the target | broken-symlink shape: README mentions `build.sh -> ...`; on-disk symlink present (target absent) → SILENT |
| [7] zh-TW heading '## 目錄結構' is recognized | translated heading also enters the tree-walker → FIRE on stale path |
| [7] silent when README has no Directory Structure section | no tree section at all → SILENT (walker no-op) |

### test/smoke/remind_docker_for_lint_spec.bats (14)
| Test | Scenario |
|------|----------|
| fires on standalone shellcheck | bare `shellcheck ...` → FIRE |
| fires on standalone bats | bare `bats ...` → FIRE |
| fires on standalone hadolint | bare `hadolint ...` → FIRE |
| silent inside docker run wrapper | `docker run ... shellcheck ...` → SILENT |
| silent inside ./build.sh test wrapper | `./build.sh test` → SILENT |
| silent inside make -f Makefile.ci wrapper | `make -f Makefile.ci lint` → SILENT |
| silent on unrelated command containing the word bats in path | `ls /usr/lib/bats-core` → SILENT |
| silent inside make -C .claude/test wrapper (default list) | `make -C .claude/test test` → SILENT |
| lint_wrappers.txt overrides default list | sibling file lists custom wrapper → matches custom, SILENT |
| lint_wrappers.txt override drops the default docker pattern | with override list = `make -C .claude`, `docker run ...; bats foo` → FIRE |
| lint_wrappers.txt ignores blank and # comment lines | non-content lines skipped during parse |
| missing CLAUDE_PROJECT_DIR falls back to default list | unset env, `docker run ... shellcheck ...` → SILENT |

### test/smoke/remind_no_ai_attribution_spec.bats (5)
| Test | Scenario |
|------|----------|
| fires on git commit -m with Co-Authored-By: Claude | inline marker → FIRE |
| fires on gh pr create with Generated with [Claude Code] | inline marker → FIRE |
| fires on gh issue comment with attribution | inline marker → FIRE |
| silent on git commit without attribution | clean message → SILENT |
| silent on non-git/gh command containing attribution string | `echo Co-Authored-By: Claude` → SILENT |

### test/smoke/remind_ci_auto_merge_spec.bats (6)

Covers `.claude/hooks/remind_ci_auto_merge.sh` (renamed from
`remind_pr_wait_ci`; refs #211). PreToolUse on Bash matcher; fires ONLY
on `gh pr create`, instructing the agent to land the PR via the
`auto-merge-on-green` skill. `git push` is owned by
`remind_monitor_on_git_push`, so this hook stays silent on it.

| Test | Scenario |
|------|----------|
| fires on gh pr create -> auto-merge-on-green | direct invocation → FIRE |
| fires on chained command containing gh pr create | `... && gh pr create` → FIRE |
| silent on gh pr list | non-create gh command → SILENT |
| silent on git push (owned by remind_monitor_on_git_push) | `git push` → SILENT |
| silent on unrelated command | `echo hello` → SILENT |
| silent on empty command | empty input → SILENT |

### test/smoke/auto_merge_on_green_spec.bats (12)

Covers `.claude/scripts/auto-merge-on-green.sh` (refs #211; ported from
initialization#154/#155). PATH-stubs `gh` so `gh pr view` returns a
canned `mergeStateStatus` fixture and merge / update-branch are logged
no-ops; `--no-arm --interval 0 --max-iterations N` make the poll loop
deterministic. The gh-call log asserts arm / update-branch side effects.

| Test | Scenario |
|------|----------|
| arg validation: missing --repo -> exit 2 | required-arg |
| arg validation: non-numeric --pr -> exit 2 | arg type |
| arg validation: bad --merge-method -> exit 2 | enum validation |
| MERGED -> exit 0 with MERGED line | terminal success |
| required check FAILURE while BLOCKED -> FAIL exit 1 | check failed, left armed |
| merge conflict DIRTY -> FAIL exit 1 with rebase hint | conflict terminal |
| closed unmerged -> FAIL exit 1 | closed terminal |
| BEHIND -> runs gh pr update-branch, stays pending | strict-staleness nudge |
| pending check still running -> keeps polling (max-iter 124) | pending keeps waiting |
| BLOCKED with no pending/failed check past grace -> FAIL blocked | grace bail |
| no PR (empty gh view) -> FAIL exit 1 | missing PR |
| arm step runs gh pr merge --auto --squash --delete-branch | arm side effect |

### test/smoke/serial_merge_spec.bats (9)

Covers `.claude/scripts/serial-merge.sh` (issue #235) — lands N same-repo
PRs serially by delegating each to `auto-merge-on-green.sh` one at a time
(so at most one PR is ever armed, turning the O(N^2) CI re-run blow-up
under strict branch protection into O(N)). The delegate is seamed via the
`SERIAL_MERGE_DELEGATE` env override to a fake that logs its `--repo`/`--pr`
and exits per `FAIL_PRS`; `gh` is also PATH-stubbed to a logged no-op. The
call-log asserts ordering, default-owner prefix, and skip-and-continue.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| arg validation: missing repo arg -> exit 2 | required-arg validation |
| arg validation: repo but no PR args -> exit 2 | required-arg validation |
| arg validation: non-numeric PR -> exit 2 before any delegation | up-front validation, empty call-log |
| --dry-run prints planned order and makes no delegate/gh call | dry-run no-op (empty call-log) |
| default-owner expansion: short repo foo -> ycpss91255-docker/foo | default owner prefix |
| ordering: PRs are delegated in the given argument order | serial order preserved |
| skip-and-continue: first PR fails, second still lands, exit 1 names failed PR | continue-on-error + summary |
| all-success: every delegate exits 0 -> exit 0 with merged summary | happy path |

### test/smoke/remind_monitor_on_ci_trigger_spec.bats (13)

Covers `.claude/hooks/remind_monitor_on_ci_trigger.sh` — PreToolUse on
Bash matcher. Sibling of `remind_ci_auto_merge`; fires when the agent
triggers a new CI run via `gh workflow run` (workflow_dispatch) or
`gh run rerun` (re-running a previous run), reminding to Monitor the
resulting run via `wait-tag-ci.sh` / `/wait-pr-ci` instead of
sleep-polling. Refs #154.

| Test | Scenario |
|------|----------|
| fires on gh run rerun (PR + tag hints) | direct re-run → message contains both `wait-pr-ci` + `wait-tag-ci` |
| fires on gh run rerun --failed | re-run failed-only flavour → FIRE |
| fires on gh workflow run (tag-scoped hint) | workflow_dispatch → message contains `wait-tag-ci` |
| fires on gh workflow run --ref refs/heads/main | branch dispatch flavour → FIRE |
| fires on chained command containing gh workflow run | `git push tag && gh workflow run ... --ref tag` → FIRE |
| fires on chained command containing gh run rerun | `gh pr checks ; gh run rerun ...` → FIRE |
| silent on gh run list | listing only → SILENT |
| silent on gh run view | inspecting only → SILENT |
| silent on gh run watch | watching is itself the recommended path → SILENT |
| silent on gh workflow list | listing only → SILENT |
| silent on gh workflow view | inspecting only → SILENT |
| silent on unrelated command | `echo hello` → SILENT |
| silent on empty command | empty input → SILENT |

### test/smoke/remind_monitor_on_git_push_spec.bats (11)

Covers `.claude/hooks/remind_monitor_on_git_push.sh` — PreToolUse on
Bash matcher. Completes the CI-watch umbrella (#157): fires when a
`git push` re-pushes / force-pushes an existing PR branch (CI re-runs
on the new head, no `gh pr create` event covers it), reminding to
re-invoke `/wait-pr-ci` on the same PR. Silent on initial `-u` pushes
(the following `gh pr create` reminder covers them), main pushes
(doc-only), and tag pushes (owned by `enforce_semver_tag_via_script`).

| Test | Scenario |
|------|----------|
| fires on git push --force-with-lease | rebase re-push → FIRE |
| silent on git push -u origin feat/x (initial push) | initial push, gh pr create covers → SILENT |
| silent on git push --set-upstream origin feat/x | long-form -u → SILENT |
| silent on git push origin main (doc-only direct) | main target → SILENT |
| fires on plain git push (re-push to existing upstream) | bare re-push → FIRE |
| fires on git push origin feat/x without -u (re-push) | branch re-push → FIRE |
| fires on git -C <dir> push --force-with-lease | -C global flag form → FIRE |
| silent on version-tag push (git push origin vX.Y.Z) | tag push, semver hook owns → SILENT |
| silent on non-push git command (git status) | non-push git → SILENT |
| silent on non-git command (ls) | non-git → SILENT |
| silent on bulk tag push variant | --tags bulk → SILENT |

### test/smoke/remind_tdd_categories_spec.bats (13)
| Test | Scenario |
|------|----------|
| fires on .sh file edit | shell logic → FIRE |
| fires on Dockerfile edit | Dockerfile → FIRE |
| fires on compose.yaml edit | compose → FIRE |
| fires on entrypoint.sh edit | entrypoint specific reminder → FIRE |
| fires on .hadolint.yaml edit | lint rule edit → FIRE |
| silent on .md edit | docs → SILENT |
| silent on .bats edit | test file → SILENT |
| silent on .claude/ internals | hook self-edits → SILENT |
| [#75] .sh in downstream repo with only test/smoke/ drops Unit + Integration | repo-detect: ros1_bridge layout → only Smoke + Lint clauses |
| [#75] .sh in repo with full test infra keeps all 4 categories | repo-detect: template layout → all 4 clauses |
| [#75] Dockerfile in repo with only test/smoke/ keeps Smoke + Lint | repo-detect on Dockerfile path |
| [#75] repo without any test/ subdir falls back to all 4 categories | fallback preserves pre-#75 behaviour |
| [#220] .sh in repo detected via root justfile only (no Dockerfile) scopes categories | repo-detect: base/downstream root-justfile marker |

### test/smoke/remind_no_heredoc_redirect_spec.bats (10)
| Test | Scenario |
|------|----------|
| fires on cat <<'EOF' > /path | quoted heredoc to file → FIRE |
| fires on cat << EOF > /path (no quotes) | unquoted heredoc → FIRE |
| fires on cat <<-EOF > /path (dash form) | tab-stripping heredoc → FIRE |
| fires on cat <<EOF >> /path (append redirect) | append `>>` form → FIRE |
| silent on plain echo > file (no heredoc) | simple redirect → SILENT |
| silent on cat /file > /other (no heredoc) | file-to-file copy → SILENT |
| silent on heredoc piped to command (no file redirect) | `cat <<EOF \| sh` → SILENT |
| silent on git commit message describing the pattern (false-positive guard) | `git commit -m "...cat <<EOF > path..."` → SILENT |
| silent on bash -c "cat <<EOF > path" (allowed wrapper) | `bash -c` wraps the heredoc → SILENT |
| fires on chained command: git status && cat <<EOF > /path | command-position heredoc after `&&` → FIRE |

### test/smoke/remind_no_chinese_in_git_artifacts_spec.bats (11)

Covers `.claude/hooks/remind_no_chinese_in_git_artifacts.sh` — blocking
PreToolUse hook that DENIES `git commit` and `gh pr|issue` commands when
the commit message / PR or issue title / body / comment contains CJK
ideographs (U+4E00-9FFF / Ext-A) or fullwidth punctuation + ASCII forms
(U+3000-303F / U+FF00-FFEF). README*.md and i18n / locale files are
exempt from `--body-file` scanning.

| Test | Scenario |
|------|----------|
| denies git commit -m with CJK ideograph | inline CJK in commit message → DENY |
| denies gh pr create --body with fullwidth comma | fullwidth punctuation in PR body → DENY |
| denies gh issue create --body with fullwidth digit | fullwidth digit in issue body → DENY |
| denies gh issue close --comment with CJK punctuation | CJK fullstop in --comment → DENY |
| denies gh pr comment --body-file pointing at file with CJK | file body with CJK → DENY |
| silent on gh pr create --body-file pointing at README.zh-TW.md (exempt) | exempt file → SILENT |
| silent on gh issue create --body-file pointing at i18n.sh (exempt) | i18n exempt file → SILENT |
| silent on git commit -m with plain English | no CJK → SILENT |
| silent on git commit -m with em-dash and smart quotes (English typography) | allowed non-ASCII typography → SILENT |
| silent on non-git/gh command containing CJK | matcher narrows to git/gh subcommands → SILENT |
| silent on gh pr list --json (no body/title editing) | non-editing gh subcommand → SILENT |

### test/smoke/remind_test_tools_smoke_sync_spec.bats (7)
| Test | Scenario |
|------|----------|
| fires on Dockerfile.test-tools edit, listing apk packages and smoke commands | edit Dockerfile.test-tools → FIRE with both lists |
| lists every package on the final stage apk add line | final-stage parsing covers full payload |
| ignores apk add lines from non-final stages | only final stage is parsed |
| silent when sibling release-test-tools.yaml is missing | YAML missing → SILENT |
| silent on unrelated Dockerfile | non-target Dockerfile → SILENT |
| silent when Dockerfile.test-tools has no final-stage apk add | no final apk → SILENT |
| handles empty smoke step gracefully | YAML run block empty → no crash |

### test/smoke/enforce_gh_body_file_spec.bats (54)

Covers `.claude/hooks/enforce_gh_body_file.sh` -- the PreToolUse hook
that BLOCKS gh routing violations from issue #64. Renamed + upgraded
from `remind_use_body_file.sh` (non-blocking remind). 8 rules across
issue/pr create, comment, edit, close, review. 80-char single-line
threshold for short inline bodies.

| Test | Scenario |
|------|----------|
| rule 8: gh issue close --comment "$(cat path)" denied | cat substitution → DENY |
| rule 8: gh pr create --body "$(cat path)" denied | cat substitution → DENY |
| rule 8: gh pr edit --body $(cat path) without quotes denied | unquoted substitution → DENY |
| rule 8: gh pr create --body-file - <<EOF heredoc denied | `--body-file -` heredoc → DENY |
| rule 8: gh issue create --body-file - alone (stdin variant) denied | `--body-file -` alone → DENY |
| rule 1: gh issue create without --body-file denied | inline body present, no `--body-file` → DENY |
| rule 1: gh issue create with --body-file + --label allowed (silent) | canonical (Rule 1 + Rule 9) → SILENT |
| rule 9: gh issue create with --body-file but no --label denied | label missing → DENY (issue #91) |
| rule 9: gh issue create with --label= form allowed | `=` form variant → SILENT |
| rule 9: gh issue create with -l short form allowed | short flag → SILENT |
| rule 9: gh issue create with quoted multi-word label allowed | quoted value → SILENT |
| rule 9: gh issue create with two --label flags allowed | multi-label → SILENT |
| rule 9: gh issue create with empty --label "" denied | empty value → DENY |
| rule 9: gh issue create with --label= (empty after equals) denied | empty `=` value → DENY |
| rule 9: gh pr create without --label still allowed (PR exempt) | PRs inherit labels from closed issues → SILENT |
| rule 4: gh pr create without --body-file denied (short inline body) | even short `--body "LGTM"` on create → DENY |
| rule 4: gh pr create with --body-file /tmp/x.md allowed | canonical → SILENT |
| rule 4: gh pr create --body-file path with dash-like name allowed | path with `-` but not literal `-` → SILENT |
| rule 3: gh issue close N --comment "..." denied | `--comment` on close → DENY (two-step required) |
| rule 3: gh issue close N -c "..." (short form) denied | short form of `--comment` → DENY |
| rule 3: python3 -c mentioning gh issue close in a literal is NOT blocked | `-c` of another program, scoped out → SILENT (#219) |
| rule 3: git log -S for the gh issue close string is NOT blocked | string-only match, no flag → SILENT (#219) |
| rule 3: gh issue close N (no comment) chained before another -c command is allowed | `-c` after `&&` cut from close-segment → SILENT (#219) |
| rule 3: gh issue close N --reason completed (no comment) allowed | reason-only close → SILENT |
| rule 3: gh issue close N --reason "not planned" allowed | reason-only close with quoted reason → SILENT |
| rule 3: gh issue close N (no args beyond N) allowed | bare close → SILENT |
| rule 6: gh pr edit N --body "inline" denied | edit inline body → DENY |
| rule 6: gh pr edit N --body-file /tmp/x.md allowed | edit via file → SILENT |
| rule 6: gh pr edit N --add-label "x" (no body) allowed | edit without body → SILENT |
| rule 2: gh issue comment N --body "<=80 single-line" allowed | short inline → SILENT |
| rule 2: gh issue comment N --body "<long string>" denied | long inline → DENY |
| rule 5: gh pr comment N --body "<=80" allowed | short inline → SILENT |
| rule 5: gh pr comment N --body "<long>" denied | long inline → DENY |
| rule 7: gh pr review --body "LGTM" allowed | short review → SILENT |
| rule 7: gh pr review --body "<long>" denied | long review → DENY |
| silent on non-gh command using $(cat path) | non-gh → SILENT |
| silent on gh pr view (no body involvement) | read-only subcmd → SILENT |
| silent on gh pr merge --auto (no body) | merge subcmd → SILENT |
| silent on gh run view <id> --json jobs | run-scoped read → SILENT |
| silent on gh api /repos/.../issues/N | raw api read → SILENT |
| silent on empty tool_input | defensive |
| silent on non-Bash tool_input shape (e.g. Edit) | wrong tool → SILENT |
| rule 2: gh issue comment --body "<exactly 80 chars>" allowed | boundary lower side → SILENT |
| rule 2: gh issue comment --body "<81 chars>" denied | boundary upper side → DENY |
| #196 A: pr create closing #N without decision record denied | closing PR needs ## Resolution/Decision (issue #196) |
| #196 A: pr create closing #N WITH ## Resolution allowed | marker present → SILENT |
| #196 A: pr create closing #N WITH ## Decision allowed | Decision marker equivalent |
| #196 A: pr create NOT closing any issue needs no decision record | non-closing PR unaffected |
| #196 A: pr create with unreadable body-file fails open (silent) | fail-open on missing file |
| #196 B: issue close with no marker comment denied | manual close needs marker comment |
| #196 B: issue close WITH ## Resolution comment allowed | marker comment present → SILENT |
| #196 B: issue close WITH ## Decision comment allowed | Decision marker equivalent |
| #196 B: issue close fails open when gh errors (network) | fail-open on gh failure |
| #196 B: issue close N --reason still passes Check B with marker comment | reason flag + marker → SILENT |

### test/smoke/wait_pr_ci_spec.bats (32)

Covers `.claude/scripts/wait-pr-ci.sh` (the PR-scoped polling loop extracted
out of the wait-pr-ci skill so the Monitor body becomes a single command, no
parser warnings). `gh` is stubbed via PATH so the loop sees canned
`gh pr view --json` output.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| missing --repo exits 2 | required arg validation |
| missing --prs exits 2 | required arg validation |
| unknown arg exits 2 | unknown flag |
| all-pass + MERGEABLE single PR exits 0 with ALL_DONE | happy path |
| any FAILURE check exits 1 with FAIL <pr> | fail-fast on FAILURE |
| all-pass + CONFLICTING mergeable exits 1 with update-stale-pr hint | mergeable=CONFLICTING surfaces as FAIL with update-stale-pr.sh hint (issue #87 / #221) |
| mixed SUCCESS+SKIPPED rollup hits ALL_DONE | SKIPPED counts as success-equivalent (issue #86) |
| multiple PRs all-pass + MERGEABLE exits 0 | CSV PR batching |
| custom --check-filter narrows to a non-default check name | filter override (container-repo / org-profile usage) |
| max-iterations exits 124 when stuck pending | iteration cap |
| no matching checks counts as no-checks (not all-pass) and loops | empty filter result ≠ green |
| all-pass but UNKNOWN mergeable does not exit ALL_DONE | mergeable gate |
| --min-checks 2 with only 1 matching SUCCESS stays pending | subset-rollup race (issue #66) |
| --min-checks default 1 preserves backwards-compatible behaviour | positive control |
| status IN_PROGRESS blocks all-pass even when conclusion field absent | status-guard demotion |
| status COMPLETED + conclusion SUCCESS reaches ALL_DONE | positive control |
| --min-checks non-integer exits 2 | arg validation |
| --min-checks 0 exits 2 (must be positive) | arg validation |
| all-pass with all completedAt predating watch start → pending | stale-rollup completedAt guard (issue #60) |
| all-pass with completedAt newer than watch start → ALL_DONE | positive control for completedAt guard |
| headRefOid change between polls emits [head-moved] and forces pending | headRefOid guard (issue #60) |
| stable headRefOid across polls preserves ALL_DONE path | negative control for headRefOid guard |
| JSON without headRefOid preserves backwards-compatible behaviour | mocks without headRefOid keep working |
| state=MERGED with mergeable=UNKNOWN exits 0 with ALL_DONE | auto-merge race short-circuit (issue #113) |
| state=CLOSED without merge exits 1 with FAIL <pr> | terminal failure (issue #113) |
| state-transition mid-poll OPEN/pending -> MERGED reaches ALL_DONE | mid-poll race (issue #113) |
| absent .state field preserves backwards-compatible behaviour | legacy stubs without .state keep working |
| ALL_DONE appends one JSON event line with full schema | event-log emit (issue #175 Phase 1) |
| FAIL appends event line with exit_reason=FAIL | event-log emit (issue #175 Phase 1) |
| max-iterations appends event line with exit_reason=timeout_max_iter | event-log emit (issue #175 Phase 1) |
| write failure is silent: log path is a dir (EISDIR) -> script still ALL_DONE | non-fatal emit (issue #175 Phase 1) |

### test/smoke/wait_pr_ci_batch_spec.bats (37)

Covers `.claude/scripts/wait-pr-ci-batch.sh` — multi-repo flavour for
`/batch-template-upgrade` follow-up. Same Monitor pattern + output
shape as `wait-pr-ci.sh`, but takes positional `<repo>:<pr>` pairs
and aggregates all PRs into one stream.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| no pairs exits 2 | required-arg validation |
| bad pair (no colon) exits 2 | format validation |
| non-numeric PR exits 2 | PR validation |
| unknown flag exits 2 | flag validation |
| all-pass single short-form pair exits 0 with ALL_DONE | happy path + default owner prefix |
| full owner/repo form is accepted (no prefix added) | full form override |
| --owner overrides default for short form | owner flag |
| any FAILURE check exits 1 with FAIL <repo>#<pr> | failure surfacing |
| mixed SUCCESS+SKIPPED rollup hits ALL_DONE | SKIPPED counts as success-equivalent (issue #86) |
| multiple pairs all-pass + MERGEABLE exits 0 | batch happy path |
| custom --check-filter narrows to a non-default check name | container-repo filter usage |
| max-iterations exits 124 when stuck pending | iteration cap |
| no matching checks counts as no-checks (not all-pass) and loops | empty filter result ≠ green |
| all-pass but UNKNOWN mergeable does not exit ALL_DONE | mergeable gate |
| per-repo --check-filter <repo>=<expr> applies only to that repo | per-repo filter map (issue #46) |
| per-repo filter overrides default for one repo, others fall back | mixed per-repo + global default |
| per-repo filter accepts full owner/repo key form | full owner/repo as filter key |
| global --check-filter (no repo prefix) still works as before | backwards-compat global filter |
| per-repo filter with no matching check counts as no-checks | per-repo filter narrowing semantics |
| duplicate --check-filter for same repo: last one wins | last-write-wins map semantic |
| --min-checks 2 with only 1 matching SUCCESS stays pending | subset-rollup race per-pair (issue #66) |
| status IN_PROGRESS blocks all-pass (status guard) | status-guard demotion per-pair |
| per-repo --min-checks <repo>=<N> applies only to that repo | per-repo min-checks map |
| --min-checks default 1 preserves backwards-compatible behaviour | positive control |
| --min-checks non-integer exits 2 | arg validation |
| --min-checks <repo>=<non-int> exits 2 | per-repo arg validation |
| all-pass with completedAt predating watch start → pending (batch) | stale-rollup completedAt guard per-pair (issue #60) |
| headRefOid change between polls emits [head-moved] (batch) | headRefOid guard per-pair (issue #60) |
| stable headRefOid across polls preserves ALL_DONE path (batch) | negative control for headRefOid guard |
| JSON without headRefOid preserves backwards-compatible behaviour (batch) | mocks without headRefOid keep working |
| all pairs state=MERGED exits 0 with ALL_DONE (batch) | auto-merge race short-circuit per-pair (issue #113) |
| one pair state=CLOSED in batch exits 1 with FAIL (batch) | terminal failure per-pair (issue #113) |
| absent .state field preserves backwards-compatible behaviour (batch) | legacy stubs without .state keep working |
| ALL_DONE batch appends one aggregate JSON event line with pairs[] | aggregate event-log emit (issue #175 Phase 1) |
| FAIL batch appends event line with exit_reason=FAIL | aggregate event-log emit (issue #175 Phase 1) |
| max-iterations batch appends event line with exit_reason=timeout_max_iter | aggregate event-log emit (issue #175 Phase 1) |

### test/smoke/fix_dockerfile_lint_lib_spec.bats (6)

Covers `.claude/scripts/fix-dockerfile-lint-lib.sh` — the generalised
`--branch`-aware fanout patch for downstream Dockerfiles that pre-date
template #284's `_lib.sh` -> `lib/*.sh` sub-libs split.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| missing --branch exits 2 | required-arg validation |
| unknown arg exits 2 | flag validation |
| --dry-run prints plan for all default repos and exits 0 | full enumeration |
| --repos CSV narrows the repo list | filter |
| --org overrides default owner in dry-run output | owner flag |

### test/smoke/batch_open_archive_rename_issues_spec.bats (16)

Covers `.claude/scripts/batch-open-archive-rename-issues.sh` — opens 11
follow-up issues across downstream repos parked from docker_harness's
active list (7 archive + 4 rename + `.base` migration). `gh` is stubbed
via PATH; bodies land under a temp `TMPDIR` so test runs are sealed.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| unknown arg exits 2 | flag validation |
| --dry-run lists all 7 archive + 4 rename issues | full enumeration |
| --dry-run writes body files under TMPDIR | side-effect path |
| archive body has 5 standard sections + parked reason + refs line | body shape (archive) |
| rename body has 5 standard sections + new name + ROS version label + refs line | body shape (rename) |
| body omits refs section when --refs not given | refs is opt-in |
| --only filters to single archive repo | filter happy path |
| --only filters to multiple slugs across archive + rename groups | cross-group filter |
| --only with non-matching slug creates none | filter no-match |
| archive title format: 'chore: archive <repo> (out of docker_harness active list)' | title contract (archive) |
| rename title format: 'chore: rename <old> -> <new> (+ .base migration)' | title contract (rename) |
| non-dry-run calls 'gh issue create -R <owner/repo> --title ... --body-file ...' | argv shape uses --body-file (rule 1 of enforce_gh_body_file.sh) |
| --owner overrides default org for create | owner flag |
| skips create when an issue with the same title already exists | idempotent re-run |
| gh create failure counts toward 'failed' and exits 1 | failure surfacing |

### test/smoke/batch_pr_close_spec.bats (16)

Covers `.claude/scripts/batch-pr-close.sh` — close N superseded PRs across
repos with a shared `--reason` comment posted first. Sibling of
`batch-pr-merge.sh`. `gh` stubbed via PATH.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| missing --reason exits 2 | required-arg validation |
| no pairs exits 2 | required-arg validation |
| bad pair (no colon) exits 2 | format validation |
| non-numeric PR exits 2 | PR validation up-front |
| short repo name is normalized to ycpss91255-docker/<repo> | default owner prefix |
| full owner/repo form is accepted (no prefix added) | full-form override |
| --owner overrides default for short form | owner flag |
| --dry-run prints planned closes and skips gh invocation | dry-run no-op |
| successful close invokes gh pr close with --comment and --delete-branch | argv shape (happy path) |
| --no-delete-branch omits --delete-branch from gh invocation | branch-deletion toggle |
| gh failure produces summary and exits 1 | failure surfacing |
| mixed success and failure continues and reports both | continue-on-error semantics |
| unknown flag exits 2 | flag validation |
| empty repo in pair exits 2 | empty-repo guard |
| empty PR in pair exits 2 | empty-pr guard |

### test/smoke/batch_pr_merge_spec.bats (14)

Covers `.claude/scripts/batch-pr-merge.sh` — squash-merge the N PRs
opened by `batch-template-upgrade.sh` once their CI is green. Mirrors
`wait-pr-ci-batch.sh`'s argument contract (default-owner prefix +
`--owner` override + up-front PR validation) so the next-step block
printed by `batch-template-upgrade.sh` works for both scripts.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| no pairs exits 2 | required-arg validation |
| bad pair (no colon) exits 2 | format validation |
| non-numeric PR exits 2 | PR validation up-front (before any gh call) |
| short repo name is normalized to ycpss91255-docker/<repo> | default owner prefix |
| full owner/repo form is accepted (no prefix added) | full form override |
| --owner overrides default for short form | owner flag |
| --dry-run prints planned merges and skips gh invocation | dry-run no-op |
| successful merge invokes gh pr merge with --squash --delete-branch | argv shape |
| gh failure produces summary and exits 1 | failure surfacing |
| mixed success and failure continues and reports both | continue-on-error semantics |
| unknown flag exits 2 | flag validation |
| empty repo in pair exits 2 | empty-repo guard |
| empty PR in pair exits 2 | empty-pr guard |

### test/smoke/enforce_semver_tag_via_script_spec.bats (29)

Covers `.claude/hooks/enforce_semver_tag_via_script.sh` — the boundary
guard that BLOCKs raw `git tag v*` / `git push.*v[0-9]` /
`gh release create v*` and forces the caller through
`.claude/scripts/release-tag.sh` (issue #106 + #181).

| Test | Scenario |
|------|----------|
| denies git tag -a vX.Y.Z | annotated tag deny |
| denies git tag -a vX.Y.Z-rcN | RC tag deny (caller still must use script) |
| denies lightweight git tag vX.Y.Z | lightweight tag deny |
| denies git push origin vX.Y.Z | refspec push deny |
| denies git push origin refs/tags/vX.Y.Z | full refspec deny |
| denies git push --tags | bulk push deny |
| denies git push origin --tags | bulk push with remote deny |
| denies even when ACK env appears in command | ACK env on raw git still rejected |
| silent for git tag listing (-l) | list form passes |
| silent for git tag --list | list form passes |
| silent for git tag with no args (list form) | bare list form passes |
| silent for git tag -d \<tag\> (delete annotated) | delete passes |
| silent for git tag --delete \<tag\> | delete passes |
| silent for git push origin :v1.3.0 (refspec delete) | refspec delete passes |
| silent for regular branch push (no v-tag refspec) | branch push passes |
| silent for non-version tag (e.g. release-2026) | non-v tag passes |
| silent for non-git command | non-git passes |
| silent for invocation of .claude/scripts/release-tag.sh itself | canonical script invocation passes |
| denies git -C \<dir\> tag vX.Y.Z (global -C flag) | -C global flag detected |
| denies git tag -f vX.Y.Z (force re-tag) | -f flag detected |
| silent on empty command (defensive) | empty input handled |
| denies gh release create vX.Y.Z | gh CLI bypass closed (issue #181) |
| denies gh release create vX.Y.Z-rcN | gh CLI bypass for RC tags |
| denies gh release create with --repo flag | flags interleaved before / after tag |
| silent for gh release list | non-create subcommand passes |
| silent for gh release view \<tag\> | view passes |
| silent for gh release delete \<tag\> | delete passes |
| silent for gh release create non-version tag (release-2026) | non-v tag passes via gh too |
| silent for gh release edit \<tag\> (metadata edit, tag already exists) | edit on existing tag passes |

### test/smoke/release_tag_spec.bats (25)

Covers `.claude/scripts/release-tag.sh` — canonical primitive for cutting
version tags with RC + ACK enforcement (issue #106). `gh` is stubbed via
PATH; `git` operations run against a real temp repo seeded per test.

| Test | Scenario |
|------|----------|
| --help exits 0 and prints usage | help path |
| missing \<tag\> exits 2 | arg validation |
| malformed tag (no v prefix) exits 2 | shape validation |
| malformed tag (extra suffix) exits 2 | shape validation |
| unknown flag exits 2 | flag validation |
| duplicate tag arg exits 2 | arg duplicate guard |
| exits 2 when .version mismatches the target tag | .version integrity |
| passes when .version matches target tag (Z bump) | .version positive control |
| no .version file -> rule N/A (Z bump still passes) | .version optional |
| RC tag itself passes without RC / ACK checks | RC short-circuit |
| RC tag passes even with no prev tag in repo | first-ever RC tag |
| Z>0 patch tag passes without RC / ACK | Z bump path |
| Z>>0 still passes (e.g. v1.3.42) | Z bump with high Z |
| Y bump blocked with no RC tag in repo | RC missing |
| Y bump passes with RC + all success CI | RC happy path |
| Y bump passes with RC + mix success/skipped (issue #86 parity) | SKIPPED counts as success-equivalent |
| Y bump blocked with RC + failing CI | RC failure |
| Y bump blocked with RC + cancelled CI | RC cancelled |
| Y bump picks latest passing RC when multiple RCs exist | rc1 -> rc2 ordering |
| X bump blocked without ACK env | X consent gate |
| X bump blocked with ACK value not matching tag literal | ACK literal-match |
| X bump passes with ACK + RC + passing CI | X happy path |
| X bump blocked even with ACK if RC CI fails | RC failure trumps ACK |
| X bump blocked with ACK but no RC tag at all | RC missing trumps ACK |
| --dry-run does not create any tag | dry-run preview |

### test/smoke/new_adr_spec.bats (16)

Covers `.claude/scripts/new-adr.sh` -- the canonical creator for
Architecture Decision Records. Each test runs against a fresh
temp repo seeded with `git init`, so the `git rev-parse --show-toplevel`
resolution + `doc/adr/` mkdir paths get exercised end-to-end.
Refs issue #97.

| Test | Scenario |
|------|----------|
| --help exits 0 with usage | help path |
| missing slug exits 2 | arg validation |
| invalid slug (uppercase) exits 2 | shape validation |
| invalid slug (underscore) exits 2 | shape validation |
| invalid slug (leading dash) exits 2 | shape validation |
| invalid slug (double dash) exits 2 | shape validation |
| slug too long exits 2 | length cap (80) |
| unknown flag exits 2 | flag validation |
| first ADR gets number 00000001 | bootstrap numbering |
| second ADR gets number 00000002 | increment |
| auto-numbering picks max+1 across non-contiguous existing ADRs | max-scan |
| rejects collision when same slug already exists | filename-collision guard |
| template body contains all 4 sections | template rendering (Context / Decision / Alternatives / Consequences) |
| title-cases the slug in the H1 | slug -> title-case transform |
| --dry-run does not create the file | preview mode |
| creates doc/adr/ directory when missing | mkdir bootstrap |

### test/smoke/remind_adr_on_design_decision_spec.bats (12)

Covers `.claude/hooks/remind_adr_on_design_decision.sh` -- Stop
hook that nudges `/adr` when a session shows rationale-shaped
exchanges but landed no `doc/adr/` Write/Edit. Transcript JSONL
is synthesised inline via the `emit_text` / `emit_tool_use`
helpers. Refs issue #97.

| Test | Scenario |
|------|----------|
| silent on empty transcript | defensive |
| silent with one rationale hit (below threshold) | threshold gate |
| fires with 3 rationale hits (threshold met) | happy path |
| silent when doc/adr/ Write happened in same session | activity-suppression |
| silent when stop_hook_active=true (re-entry guard) | recursion guard |
| silent when ADR_REMIND_DISABLE=1 | env disable |
| rationale match is case-insensitive | regex flag |
| custom threshold via env | ADR_REMIND_THRESHOLD override |
| Edit (not just Write) on doc/adr/ also counts as ADR activity | tool-use matcher |
| non-ADR Write does not suppress the nudge | path filter |
| throttle: second fire with same signal-bucket silent | TMPDIR marker |
| silent on missing transcript_path | defensive |

### test/smoke/update_stale_pr_spec.bats (14)

Covers `.claude/scripts/update-stale-pr.sh` (refs #87 / #221) -- the
one-shot `git merge origin/<base>` + normal push primitive (NO rebase,
NO force) for a PR whose base branch has moved (`mergeStateStatus:
BEHIND` / `CONFLICTING`). Renamed from `rebase-pr.sh`. `gh` is stubbed
via PATH; `git` runs against real temp worktrees so the auto-resolver's
branch-name match is exercised end-to-end.

| Test | Scenario |
|------|----------|
| --help exits 0 and prints usage | help path |
| missing \<pr\> exits 3 | arg validation |
| non-numeric \<pr\> exits 3 | shape validation |
| unknown flag exits 3 | flag validation |
| duplicate positional exits 3 | arg duplicate guard |
| gh failure (PR not found) exits 3 | upstream lookup failure |
| non-OPEN PR exits 3 | state guard (MERGED / CLOSED) |
| no matching worktree exits 3 with hint | worktree-resolver miss |
| --worktree pointing at non-existent path exits 3 | explicit-path validation |
| auto-resolves worktree by branch via WORKSPACE_DIR scan | resolver happy path |
| --worktree overrides auto-resolution | explicit override |
| --dry-run prints planned merge commands, no fetch / merge / push | dry-run preview |
| --dry-run honours non-main base branch | non-main base support |
| clean run invokes git merge + normal push, never rebase / force | merge-update mechanism |

### test/smoke/enforce_merge_update_not_rebase_spec.bats (21)

Covers `.claude/hooks/enforce_merge_update_not_rebase.sh` (refs #221) --
PreToolUse (Bash). DENIES `git rebase` (any position, incl. `git -C`,
and `git pull --rebase`) steering to `git merge origin/main`; DENIES
`git push --force`/`-f`/`--force-with-lease` ONLY on a branch that has
an open PR (`gh pr list --head`), steering to merge-update. Recovery
flags (`--abort`/`--continue`/`--skip`), no-PR force-push, gh errors,
and non-git commands stay silent (fail-open). Deny is checkpoint +
touch-ACK overridable. `gh` mocked on PATH; setup seeds a real branch.

| Test | Scenario |
|------|----------|
| git rebase main -> deny | rebase denied |
| git rebase -i HEAD~3 -> deny | interactive rebase denied |
| git -C some/dir rebase origin/main -> deny | -C form denied |
| git pull --rebase -> deny | pull --rebase denied |
| git rebase --abort -> silent (recovery exempt) | recovery flag |
| git rebase --continue -> silent (recovery exempt) | recovery flag |
| git rebase --skip -> silent (recovery exempt) | recovery flag |
| git push --force on branch WITH open PR -> deny | force-push gated on open PR |
| git push --force-with-lease origin feat/x WITH open PR -> deny | lease variant + explicit branch |
| git push --force on branch with NO open PR -> silent (fail-open) | no-PR force-push allowed |
| git push --force when gh errors / unavailable -> silent (fail-open) | gh failure fail-open |
| plain git push (no force) -> silent | non-force push |
| non-git command (ls) -> silent | out of scope |
| empty command -> silent | empty input |
| git rebase after ack file exists -> allow | checkpoint ACK override |
| B1: force flag from a chained non-git command does not trip force-push | segment-scoped, `git push .. && docker build -f` stays silent |
| B2: git push -f origin HEAD resolves HEAD to the current branch and denies | HEAD/@ maps to current branch (keyed gh stub) |
| N1: global -c option before rebase is still denied | subcommand parse skips globals |
| N1: global -c option before push --force is still gated | subcommand parse skips globals |
| N2: rebase inside a commit message is not treated as a rebase | subcommand=commit, not rebase |
| N3: +refspec force-push on an open-PR branch is denied | `+refspec` force detected |

### test/smoke/wait_tag_ci_spec.bats (14)

Covers `.claude/scripts/wait-tag-ci.sh` (the sibling script for
tag/branch-triggered workflows — `gh run list --branch <ref>` instead of
`gh pr view`). Same Monitor-wrap shape, same exit codes. `gh` is stubbed
via PATH.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| missing --repo exits 2 | required arg validation |
| missing --branch exits 2 | required arg validation |
| unknown arg exits 2 | unknown flag |
| all runs completed + success exits 0 with ALL_DONE | happy path |
| mixed success+skipped runs hit ALL_DONE | skipped counts as success-equivalent (issue #86) |
| any completed run with conclusion != success exits 1 with FAIL <name> | fail on completed-non-success |
| any in_progress run keeps polling and hits max-iterations 124 | partial completion stays pending |
| empty run list (tag just pushed) keeps polling and hits max-iterations 124 | total==0 ≠ green |
| custom --check-filter narrows to a specific run name | filter ignores out-of-scope in-progress runs |
| cancelled conclusion counts as failure | non-success conclusion handling |
| ALL_DONE tag appends one JSON event line with branch field | event-log emit (issue #175 Phase 1) |
| FAIL tag appends event line with exit_reason=FAIL | event-log emit (issue #175 Phase 1) |
| max-iterations tag appends event line with exit_reason=timeout_max_iter | event-log emit (issue #175 Phase 1) |

### test/smoke/check_log_helper_usage_spec.bats (13)

Covers `.claude/scripts/check-log-helper-usage.sh` (CI lint that
enforces `lib/log.sh` adoption in `.claude/scripts/*.sh`; refs
`#148` M5). Validates: arg-parse, scripts-dir resolution, the
`usage()` body allowlist (always skipped), the file-wide
`# log-allow:script` marker, the block-level
`# log-allow:start..end` markers, `lib/` subdirectory exclusion,
and a smoke pass against the actual docker_harness scripts dir.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| unknown arg exits 2 | arg parse error |
| non-existent scripts dir exits 2 | path validation |
| empty scripts dir passes | zero-script clean exit |
| script using only _log_* passes | no violations |
| bare printf without marker fails with line number | core violation detection |
| bare echo without marker fails | echo + printf both detected |
| printf inside usage() is allowed | usage-body allowlist |
| file-wide # log-allow:script marker skips file | file-wide pragma |
| block markers log-allow:start..end suppress violations inside | block pragma |
| multiple violations across files are all reported | multi-file aggregation |
| lib/ subdirectory is NOT scanned (only top-level *.sh) | lib/ exclusion |
| real repo passes the lint (smoke against actual docker_harness) | self-host smoke |

### test/smoke/remind_log_helper_spec.bats (7)

Covers `.claude/hooks/remind_log_helper.sh` (PostToolUse hook that
delegates to `check-log-helper-usage.sh` for the touched file
only). Validates: skip on non-script paths, skip on `lib/`, skip on
clean / allowed files, fire on bare `printf` / `echo` (refs `#148`
M5).

| Test | Scenario |
|------|----------|
| silent on non-script file | path-filter (not under .claude/scripts/) |
| silent on .claude/scripts/lib/*.sh (lib is excluded) | lib/ excluded |
| silent when file does not exist | safety net |
| silent on script that uses _log_* only | no violation |
| silent on script with file-wide log-allow:script marker | file-wide pragma |
| fires on bare printf outside usage() | core fire path |
| fires on bare echo outside usage() | echo + printf both fire |

### test/smoke/check_template_versions_spec.bats (7)

Covers `.claude/scripts/check-template-versions.sh` (read-only HTTPS fetch
of `.base/.version` for every downstream repo, used during release
verification). Replaces an ad-hoc multi-repo for-loop curl pattern that
trips the bash AST parser. `curl` is stubbed via PATH so the script runs
without network.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| unknown arg exits 2 | unknown flag |
| --only narrows to listed repos and prints versions | scope filter |
| missing version maps to MISSING | non-zero curl exit handling |
| --expect matches all → exit 0 | release-verify happy path |
| --expect mismatch → exit 1 | release-verify partial-rollout failure |
| --skip removes listed repo from default iteration | exclusion filter |

### test/smoke/batch_mutation_pr_spec.bats (12)

Covers `.claude/scripts/batch-mutation-pr.sh` (refs #169) — the generic
cross-repo fanout engine. Tests the deterministic surface (arg
validation + `--dry-run` plan); real worktree/push/PR is not exercised
(mirrors `batch_gitignore_add_line_spec`). The engine runs a
caller-supplied `--mutation <script>` per repo (exit 0 = changed,
3 = no-op, other = error) and owns the worktree → commit → push → PR
plumbing.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| missing --mutation exits 2 | required arg |
| non-executable --mutation exits 2 | executable precondition |
| missing --pr-title exits 2 | required arg |
| missing --why-file and --why exits 2 | required arg |
| invalid --commit-type exits 2 | enum validation (fix/feat/chore) |
| unknown arg exits 2 | arg validation |
| --dry-run prints a plan line per repo without mutating | dry-run plan |
| --skip excludes a repo in dry-run | repo-set filtering |
| branch derives from --commit-type + --pr-title slug | branch derivation |
| explicit --branch overrides the derived slug | branch override |
| valid --commit-type fix accepted in dry-run | enum positive |

### test/smoke/batch_line_edit_spec.bats (4)

Covers `.claude/scripts/batch-line-edit.sh` (refs #169) — the first
preset over the engine: append a line to a file across repos if absent.
It generates an append-line-if-missing mutation (idempotent: exit 3 if
the line is already present) and delegates to `batch-mutation-pr.sh`.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| missing --file exits 2 | required arg |
| missing --line exits 2 | required arg |
| --dry-run delegates to the engine (shows repos + plan) | delegation |

### test/smoke/batch_gitignore_add_line_spec.bats (7)

Covers `.claude/scripts/batch-gitignore-add-line.sh` (generic sister
of `batch-gitignore-fix.sh` that **appends** an arbitrary line to each
downstream `.gitignore` if absent — idempotent, mirrors the same
`--why` / `--only` / `--skip` / `--dry-run` / `--continue-on-error`
shape). Smoke-only; no network in tests.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| missing --line exits 2 | required-arg validation |
| missing --why-file and --why exits 2 | required-arg validation |
| unknown arg exits 2 | unknown flag |
| --dry-run prints would-do line per repo without mutating | dry-run path |
| --only narrows to listed repos in dry-run | scope filter |
| branch name slugifies the --line value | safe branch-name derivation |

### test/smoke/batch_gitignore_fix_spec.bats (5)

Covers `.claude/scripts/batch-gitignore-fix.sh` (one-shot helper that
opens one chore PR per downstream repo to replace `.claude/` with
`.claude` in `.gitignore`, so per-repo Claude session symlinks no
longer pollute `git status`). Smoke-only; no network in tests.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| missing --why-file and --why exits 2 | required-arg validation |
| unknown arg exits 2 | unknown flag |
| --dry-run prints would-do line per repo without mutating | dry-run path |
| --only narrows to listed repos in dry-run | scope filter |

### test/smoke/ci_wall_time_compare_spec.bats (14)

Covers `.claude/scripts/ci-wall-time-compare.sh` — fetches two
`gh run view --json jobs` payloads, diffs per-job wall time + overall,
and prints a markdown table. Bats stubs `gh` per run-id and asserts
the formatted output / exit codes.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | basic flag handling |
| missing --repo exits 2 | required flag validation |
| missing --baseline exits 2 | required flag validation |
| missing --fixed exits 2 | required flag validation |
| unknown arg exits 2 | reject typos |
| all jobs match, fixed faster -> table with negative deltas | core path, signed delta |
| fixed slower -> positive delta with + prefix | sign formatting |
| job present in only baseline is skipped (no fixed counterpart) | inner join semantics |
| in-progress run (missing completedAt) exits 2 | guard against unfinished baseline |
| in-progress fixed run (missing startedAt) exits 2 | guard against unfinished fixed |
| gh API failure exits 1 | propagate gh error |
| --output writes table to file, stdout is empty | file-output path |
| table header always present even when no jobs match | empty-match still emits header rows |
| equal durations -> +0s (0%) delta | zero-delta formatting |

### test/smoke/run_bats_in_compose_spec.bats (14)

Covers `.claude/scripts/run-bats-in-compose.sh` — wrapper around
`docker compose run --entrypoint bash <service> -c '<inline>'` that
side-steps the Claude bash AST parser fallback "Unhandled node type:
string" by exposing atomic flags (`--service`, `--suite`, `--grep`,
`--tail`, `--head`, `--compose-file`) instead of an inline shell body.
Stubs `docker` + `id` and asserts the inner shell command Claude's
parser never sees is composed correctly.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| unknown arg exits 2 | unknown flag |
| missing compose.yaml exits 2 | required-file validation |
| single-quote in --grep is rejected | guard against quoting injection |
| default suite=all targets unit + integration dirs | path-resolution default |
| --suite unit narrows to /source/test/unit/ | suite kind handling |
| --suite integration narrows to /source/test/integration/ | suite kind handling |
| --suite <path> uses literal /source/<path> | escape hatch for arbitrary path |
| default --grep produces inner cmd with grep filter pipe | grep wiring |
| --grep '' disables filter (full output) | empty pattern disables grep |
| --service overrides default service name | flag override |
| --compose-file overrides default compose.yaml | flag override |
| HOST_UID / HOST_GID env values come from id stub | env propagation |
| --head N caps output to first N lines | head/tail mutual exclusion |

### test/smoke/batch_template_upgrade_spec.bats (7)

Covers `.claude/scripts/batch-template-upgrade.sh` — the implementation
behind `/batch-template-upgrade`. After PR #34 the script self-prints a
copy-pasteable `wait-pr-ci-batch.sh` + `batch-pr-merge.sh` block at the
end of a real run, so sessions that bypass the slash command still see
the next-step path (was the root cause of the v0.15.0 ad-hoc
`/tmp/wait-batch-vX.Y.Z.sh` regression). Specs cover arg validation
plus unit tests of `print_next_step_hint` via source-with-guard.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| missing version exits 2 | required-arg validation |
| missing why exits 2 | required-arg validation |
| unknown arg exits 2 | flag validation |
| print_next_step_hint emits both wait + merge commands when pairs given | hint formatting (2+ pairs) |
| print_next_step_hint silent when no pairs | dry-run / all-skipped guard |
| print_next_step_hint preserves single pair | hint formatting (1 pair) |

### test/smoke/check_claude_md_tree_spec.bats (8)

Covers `.claude/scripts/check-claude-md-tree.sh` — CI lint that parses
the `.claude/` tree listing in CLAUDE.md and diffs against filesystem.
Builds a fake repo with a synthetic CLAUDE.md per case and asserts the
audit's exit code + output. Honours folded subdirs (e.g. `└── test/`
under hooks/) so they don't false-positive.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| missing CLAUDE.md exits 2 | required-file validation |
| missing .claude/ exits 2 | required-dir validation |
| aligned tree exits 0 | happy path |
| extra file in fs (missing from tree) exits 1 with + entry | drift: fs has more |
| extra entry in tree (missing from fs) exits 1 with - entry | drift: tree has more |
| folded subdir (test/) is honoured — no false positive | placeholder honoured |
| drift in two dirs reports both | multi-dir drift |

### test/smoke/check_claude_md_ceiling_spec.bats (7)

Covers `.claude/scripts/check-claude-md-ceiling.sh` — CI lint that
asserts a markdown file (default CLAUDE.md) stays under hard line-count
and `^##` section-count ceilings (defaults 240 / 20, env-overridable
via `MAX_LINES` / `MAX_SECTIONS`). Ships with the script alone in #127
PR-A; PR-B wires it into `make -C .claude/test check` after the slim
makes CLAUDE.md fit the ceilings.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path; usage prints both env-var names |
| missing file exits 2 | required-file validation |
| within default ceilings (240/20) exits 0 | happy path |
| lines exceed default ceiling exits 1 | line ceiling violation |
| sections exceed default ceiling exits 1 | section ceiling violation |
| MAX_LINES env override (tighter) triggers FAIL | env override respected for lines |
| MAX_SECTIONS env override (tighter) triggers FAIL | env override respected for sections |

### test/smoke/log_spec.bats (48)

Covers `.claude/scripts/lib/log.sh` -- the vendored OTel-aligned
5-level JSON logger (mirror of `ycpss91255-docker/base@v0.37.0`,
refs `#148`). Test cases mirror the upstream `base/test/unit/log_spec.bats`
content, adapted for the docker_harness mount path (`/work/.claude/scripts/lib/log.sh`),
the docker_harness body-enum vocabulary (`summary` / `repo_failed` /
`unrecognised_arg` / `precondition_missing` / `repo_skipped` /
`drift_detected` / `dry_run_cmd` etc. in `log-events.txt`), and
the test helper load path (`../lib/test_helper`).

Coverage groups (48 cases total):

| Group | Cases |
|------|-------|
| Text output (LOG_FORMAT=text): _log_info / _log_err / _log_warn / _log_debug / _log_fatal text shape + stream routing + timestamp + color | ~8 |
| JSON output (LOG_FORMAT=json): schema fields (severity_text, severity_number, body, attributes), service.name + service.lang=bash, ISO 8601 microsecond UTC timestamp, attribute key=value parsing | ~10 |
| tty-detect dispatch (LOG_FORMAT=auto): forced via redirect to confirm text on tty / JSON on non-tty | ~4 |
| LOG_FORMAT override: text on non-tty, json on tty, unknown value rejected | ~3 |
| Strict body enforcement: unregistered body causes fatal exit (return 1), error message names offending body + events file path | ~3 |
| TRACEPARENT parsing: omit fields when env unset, extract trace_id + span_id from valid 4-part env value | ~3 |
| Scoped wrappers: _log_with_trace generates new trace + restores prior env, _log_with_span pushes new span under existing trace + restores | ~4 |
| _log_with_trace prints `[trace started: <32-hex>]` once at trace creation | ~1 |
| Service name positional handling: required (errors when missing), used as attributes."service.name" | ~3 |
| code.filepath + code.lineno auto-capture from BASH_SOURCE + BASH_LINENO | ~3 |
| thread.id auto-capture (PID via $$) | ~1 |
| Color handling: NO_COLOR honored, FORCE_COLOR override, auto-detect on tty | ~3 |
| Negative: typo_event_name / not_a_real_event rejected by strict body check | ~2 |

### test/smoke/check_tag_version_consistency_spec.bats (15)

Covers `.claude/hooks/check_tag_version_consistency.sh` — PreToolUse
blocking hook that compares repo root `.version` against the tag name
on `git tag` / `git push <remote> <tag>`. Closes the gap that allowed
template v0.18.0 / v0.18.1 to ship with `.version` still on v0.17.0
(refs issue #36 Ask 1).

| Test | Scenario |
|------|----------|
| blocks git tag -a when .version mismatches | annotated tag path, FAIL → deny |
| blocks lightweight git tag when .version mismatches | bare `git tag <tag>` |
| blocks git push origin <tag> when .version mismatches | push form |
| blocks git push origin refs/tags/<tag> when .version mismatches | refspec form |
| silent when .version matches tag exactly | happy path |
| silent for rc tag matching .version | rc semver in `.version` |
| blocks rc tag when .version still on previous version | rc mismatch |
| silent when no .version at repo root (rule N/A) | template-less repo |
| silent for downstream consumer with .base/.version (no root .version) | downstream tags independent of consumed template version |
| silent on git tag -d (delete) | delete out of scope |
| silent on git push delete (:tag) | colon-delete form |
| silent on git tag listing (no positional tag) | list mode |
| silent on non-git command | unrelated command |
| resolves repo via cd subdir && git tag | cwd-resolution path |
| resolves repo via git -C and blocks mismatch | `-C` resolution path |

### test/smoke/check_prefer_dot_sh_spec.bats (20)

Covers `.claude/hooks/check_prefer_dot_sh.sh` — PreToolUse hook that
detects `docker build/run/exec/stop` and `docker compose <up|down|build|
run|exec>` calls. Denies + steers to the matching `just <verb>` recipe
when cwd has a root `justfile` defining that recipe; forces `ask` prompt
when there is no justfile or no such recipe. Read-only subs /
make-internal calls / already-asked subs (rm/push/...) stay silent.

| Test | Scenario |
|------|----------|
| deny docker build when justfile has build recipe | recipe-present, build path |
| deny docker run when justfile has run recipe | recipe-present, run path |
| deny docker exec when justfile has exec recipe | recipe-present, exec path |
| deny docker stop when justfile has stop recipe | recipe-present, stop path |
| deny docker compose up → just run | compose up → just run map |
| deny docker compose down → just stop | compose down → just stop map |
| deny docker compose build → just build | compose build map |
| deny docker compose exec → just exec | compose exec map |
| deny docker compose run → just run | compose run map |
| ask when docker build but no justfile | no-justfile fallback |
| ask when justfile present but no build recipe | justfile-without-recipe fallback |
| ask when docker compose up but no justfile | no-justfile fallback (compose) |
| silent on read-only docker subcommand (ps) | non-target sub |
| silent on read-only docker subcommand (images) | non-target sub |
| silent on docker pull (download is harmless) | pull is harmless |
| silent on docker rm (already in permissions.ask) | leave to perm rule |
| silent on non-docker command | unrelated cmd |
| silent on make (subprocess docker is not visible to Claude) | wrapper composition |
| strips single env-prefix and matches docker build | env-prefix tolerance |
| strips multiple env-prefixes and matches docker build | multi env-prefix |

### test/smoke/enforce_wrapper_first_upgrade_spec.bats (23)

Covers `.claude/hooks/enforce_wrapper_first_upgrade.sh` — BLOCKING
PreToolUse hook that DENIES three direct surfaces bypassing the
CI-runner upgrade wrapper: (1) `./.base/upgrade.sh` variants, (2)
`./template/upgrade.sh` legacy folder name, (3) `git subtree pull
--prefix=.base|template`. Detection is wrapper-adaptive (refs #202 /
base#573): the repo's wrapper is found in precedence order justfile
(`just upgrade`) > justfile.ci (`just -f justfile.ci upgrade`) >
Makefile.ci (`make -f Makefile.ci upgrade`, legacy), and the deny
message quotes the matching canonical; no wrapper present -> silent.
All three raw surfaces skip the init.sh symlink resync + main.yaml
`@tag` sed (refs issue #36 incident + ADR-00000005). The deny can be
lifted via the `/tmp` checkpoint protocol (ADR-00000002 / #117): the
hook writes a checkpoint markdown + quotes the matching `touch
<ack-file>` command; the second attempt of the same cmd hits
`is_acked` and is allowed through.

| Test | Scenario |
|------|----------|
| denies ./.base/upgrade.sh and writes checkpoint markdown | positive trigger + checkpoint side-effect |
| denies bare .base/upgrade.sh (no leading ./) | path-prefix variant |
| denies absolute path .base/upgrade.sh | absolute-path variant |
| deny reason mentions canonical make wrapper | reason content |
| denies ./template/upgrade.sh (legacy folder name) | surface 2 trigger |
| denies bare template/upgrade.sh (legacy, no leading ./) | surface 2 path-prefix variant |
| denies git subtree pull --prefix=.base ... | surface 3 trigger |
| denies git subtree pull --prefix=template ... (legacy prefix) | surface 3 legacy prefix |
| denies git -C <repo> subtree pull --prefix=.base ... (via -C arg) | -C arg resolution |
| silent on git subtree pull with unrelated --prefix=foo | scope discriminator |
| silent on git subtree push --prefix=.base (push, not pull) | subcommand discriminator |
| silent on make -f Makefile.ci upgrade (already going through wrapper) | wrapper path |
| silent when Makefile.ci absent (no make wrapper available) | rule N/A |
| silent when Makefile.ci has no upgrade target | rule N/A |
| silent on unrelated commands (git status) | non-trigger |
| silent on script with similar name (foo/upgrade.sh) | path-prefix discriminator |
| silent on empty command | empty-input guard |
| allows same command after ack file exists | ack-bypass |
| ack for different command does NOT bypass deny | hash isolation |

### test/smoke/enforce_batch_via_script_spec.bats (19)

Covers `.claude/hooks/enforce_batch_via_script.sh` — BLOCKING
PreToolUse hook that DENIES ad-hoc cross-repo for-loops performing
state-changing operations (`git push|reset|tag|branch -D`, or
`gh issue|pr close|merge|comment --body`). Routes the agent toward
a permanent `.claude/scripts/<name>.sh` (one prompt for the whole
batch instead of N prompts inducing yes-fatigue). Read-only loops
(`gh pr view`, `git log`, `grep`, `cat`) and standalone (non-loop)
mutating commands pass through silently. Lift mechanism is the same
`/tmp` checkpoint protocol (ADR-00000002 / #117) used by
[[enforce-make-first-upgrade]].

| Test | Scenario |
|------|----------|
| denies for-loop with gh issue close | positive trigger + checkpoint side-effect |
| denies for-loop with git push origin tag | mutating git verb in loop |
| denies for-loop with git reset --hard | mutating git verb in loop |
| denies for-loop with git branch -D | mutating git verb in loop |
| denies for-loop with git tag (mutating) | tag create variant |
| denies for-loop with gh pr merge | mutating gh verb in loop |
| denies for-loop with gh issue comment --body | mutating gh comment variant |
| deny reason mentions permanent script under .claude/scripts/ | reason content |
| denies multi-line for-loop body | multi-line shape (newlines) |
| silent on for-loop with read-only gh pr view | read-only loop allowed |
| silent on for-loop with read-only git log | read-only loop allowed |
| silent on for-loop with grep only | read-only loop allowed |
| silent on standalone git push (no for-loop) | clause 1 missing |
| silent on standalone gh issue close (no for-loop) | clause 1 missing |
| silent when invoking permanent batch script directly | trust permanent wrapper |
| silent on git tag delete (-d) inside for-loop | delete subcommand excluded |
| silent on empty command | empty-input guard |
| allows same for-loop after ack file exists | ack-bypass |
| ack for different command does NOT bypass deny | hash isolation |

### test/smoke/enforce_serial_merge_gate_spec.bats (17)

Covers `.claude/hooks/enforce_serial_merge_gate.sh` — BLOCKING
PreToolUse hook that DENIES the 2nd+ same-repo `gh pr merge ... --auto`
arm of a batch (issue #236). On an `--auto` arm it queries the target
repo's open PRs already armed for auto-merge
(`gh pr list --repo <repo> --state open --json number,autoMergeRequest`),
excluding the PR being armed. 0 already armed → ALLOW (single arm,
silent); ≥ 1 → DENY with a data-rich message (repo + armed list +
ready-to-paste `.claude/scripts/serial-merge.sh <repo> <armed...>
<this-pr>`). Non-`--auto` merges, read-only `gh pr view`, and unrelated
commands pass through silently; the query fails open. Lift via the
`/tmp` checkpoint protocol (ADR-00000002) or the `SERIAL_MERGE=1`
bypass (env var or inline command prefix). `gh` is PATH-stubbed so
`gh pr list --json` returns a synthetic armed-PR array driven by the
`ARMED` env var.

| Test | Scenario |
|------|----------|
| silent on first arm when repo has no already-armed PR | 0 armed → allow |
| denies second same-repo arm with a data-rich message | positive trigger + message content |
| deny message contains ready-to-paste serial-merge.sh command | canonical command |
| deny writes a checkpoint markdown | checkpoint side-effect |
| short repo name expands to default owner in the message | default-owner expansion |
| excludes the PR being armed from the armed count (idempotent re-arm) | self-exclusion |
| allows same command after ack file exists | ack-bypass |
| ack for a different command does NOT bypass deny | hash isolation |
| SERIAL_MERGE=1 env bypasses the gate | env bypass |
| SERIAL_MERGE=1 inline command prefix bypasses the gate | inline prefix bypass |
| silent on non-auto gh pr merge (not an arm) | scope: --auto only |
| silent on unrelated command (git status) | non-merge command |
| silent on gh pr view (read-only) | read-only gh |
| silent on empty command | empty-input guard |

### test/smoke/enforce_local_full_ci_before_pr_spec.bats (11)

Covers `.claude/hooks/enforce_local_full_ci_before_pr.sh` — BLOCKING
PreToolUse hook that DENIES `gh pr create` / `gh pr ready` unless
local CI passed on HEAD (a `.claude/state/local-ci-pass/<sha>.ok`
marker exists, written by `ci-and-stamp.sh` on green) or only
documentation changed since the last green. `LOCAL_CI_ACK=<sha>`
overrides for the exact HEAD. Fails safe (silent) outside a git repo,
and fail-opens (silent) for a repo with no detectable CI mechanism
(no `.claude/test/Makefile` / `justfile.ci` / root `justfile`) since
nothing can stamp it (refs #176 / #208).

| Test | Scenario |
|------|----------|
| denies gh pr create when HEAD has no local-ci marker | missing marker → DENY |
| allows gh pr create when marker for exact HEAD exists | green marker → ALLOW |
| silent on non-trigger gh pr view | non-trigger → SILENT |
| allows when only CHANGELOG.md changed since the green marker | doc-only-since-green → ALLOW |
| denies when a .sh file changed since the green marker | testable change → DENY |
| allows with LOCAL_CI_ACK matching HEAD | override match → ALLOW |
| denies with LOCAL_CI_ACK not matching HEAD | override mismatch → DENY |
| gh pr ready also gated (no marker -> deny) | ready trigger → DENY |
| silent (fail safe) when cwd is not a git repo | non-repo → SILENT |
| allows when only doc/ + TEST.md changed since the green marker | multi-doc-only → ALLOW |
| fail-open: repo with no detectable CI mechanism is silent | no make/justfile.ci/justfile → SILENT (issue #208) |

### test/smoke/ci_and_stamp_spec.bats (6)

Covers `.claude/scripts/ci-and-stamp.sh` (refs #208) — runs a repo's
full CI mirror and, on green, writes the local-ci-pass marker the gate
checks. Centralises marker-writing docker_harness-side so base /
downstream PRs (not just docker_harness) can satisfy the gate; the
runner is auto-detected (`.claude/test/Makefile` → `make -C
.claude/test check`; root `justfile` + `.base/` → `just build test`;
root `justfile` without `.base/` → `just test` + `just test lint`;
none → no stamp + notice; the `.base/` subtree distinguishes a
downstream consumer from base since both carry a root justfile). The CI
runner is stubbed via a PATH shim exiting 0/1 (no real docker).

| Test | Scenario |
|------|----------|
| docker_harness-style (.claude/test/Makefile) green -> stamps marker | detect + run + stamp |
| CI command non-zero -> NO marker, propagates failure | red CI does not stamp |
| base-style (root justfile, no .base) green -> runs just test + stamps | base detection (#220) |
| downstream (root justfile + .base subtree) green -> runs just build test + stamps | downstream detection (#220) |
| no CI mechanism -> no stamp, exit 0, notice | fail-open passthrough |
| marker filename is the exact HEAD sha | sha-keyed marker |

### test/smoke/enforce_worktree_for_branch_spec.bats (14)

Covers `.claude/hooks/enforce_worktree_for_branch.sh` — BLOCKING
PreToolUse hook that DENIES `git checkout -b|-B <branch>` in the
main checkout (where `--git-dir` == `--git-common-dir`). Routes
the agent to `git worktree add <path> -b <branch> main` so the
main checkout keeps ff-tracking origin/main HEAD (PR #89 precedent
+ ADR-00000006). Inside a worktree (`--git-dir` != `--git-common-dir`)
the hook falls through silently. `git switch -c` is out of scope for
now. Lift via the same `/tmp` checkpoint protocol (ADR-00000002 /
#117) as [[enforce-make-first-upgrade]] /
[[enforce-batch-via-script]].

| Test | Scenario |
|------|----------|
| denies git checkout -b feat/x in main checkout | positive trigger + checkpoint side-effect |
| denies git checkout -B feat/x (capital B) | -B variant |
| denies git -C <main-path> checkout -b feat/x | -C arg resolution |
| deny reason mentions git worktree add | reason content |
| silent on git checkout -b inside a worktree | worktree pass-through (cwd) |
| silent on git -C <worktree-path> checkout -b | worktree pass-through (-C) |
| silent on git checkout main (switch existing branch, no -b) | non-create form |
| silent on git checkout -- file.txt (path restore) | path-restore form |
| silent on git checkout some-existing-branch | existing branch switch |
| silent on unrelated commands (git status) | non-trigger |
| silent on empty command | empty-input guard |
| silent when cwd is not a git repo | repo discovery failure |
| allows same checkout -b after ack file exists | ack-bypass |
| ack for different branch does NOT bypass deny | hash isolation |

### test/smoke/check_no_stale_template_refs_spec.bats (12)
| Test | Scenario |
|------|----------|
| fires on template/script/docker reference in .base/script/docker/*.sh | stale `_lib.sh` source ref → FIRE |
| fires on template/init.sh reference | stale init path → FIRE |
| fires on template/upgrade.sh reference | stale upgrade path → FIRE |
| fires on template/dockerfile/ reference | stale Dockerfile dir → FIRE |
| fires on template/Makefile reference | stale top-level Makefile → FIRE |
| fires on Dockerfile under .base/ | Dockerfile pattern matcher → FIRE |
| silent after s\|template/\|.base/\|g | clean ref → SILENT |
| silent on literal template/ in archive/ (not under .base/) | scope guard (file outside `.base/`) |
| silent on .md file under .base/ (doc may discuss rename) | `.md` skip |
| silent on non-shell file under .base/ | extension matcher → SILENT |
| silent on missing file | defensive |
| silent on empty tool_input | defensive |

### test/smoke/setup_memory_link_spec.bats (14)

Covers `.claude/scripts/setup-memory-link.sh` — creates a symlink
from `~/.claude/projects/<encoded-workspace-path>/memory/` to
`<workspace>/.claude/memory/` so per-project memory is repo-tracked
and portable. Tests use `mktemp` workspaces + `--home` /
`--workspace` overrides so no real `$HOME` is touched.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| unknown arg exits 2 | flag validation |
| missing workspace memory dir exits 2 | precondition check |
| non-existent workspace exits 2 | input validation |
| creates symlink when project dir does not yet exist | happy path |
| creates symlink when project dir exists but memory does not | partial-state happy path |
| idempotent: existing correct symlink leaves it alone | re-run safe |
| replaces wrong-target symlink | symlink-target divergence |
| existing dir matching repo copy is replaced without --force | content-equal replacement |
| existing dir with extra file refuses without --force | data-loss guard |
| existing dir with extra file replaced with --force (backup created) | --force + backup |
| --dry-run does not modify anything | dry-run safety |
| encoded path replaces every / with - | path encoding |
| trailing slash on workspace is normalised | path normalisation |

### test/smoke/forensic_worktree_leak_spec.bats (5)

Covers `.claude/hooks/forensic_worktree_leak.sh` — Stop hook that
scans the main checkout for tracked-modified files outside the
whitelist (`.claude/instincts.yaml` + `.claude/memory/**`) and
appends a JSONL `detected` event to
`~/.claude/log/worktree-leak-events.jsonl` so the still-unidentified
worktree leak (#167) has forensic material the next time it
appears. Throttled to 5 events per session via TMPDIR marker file.

| Test | Scenario |
|------|----------|
| writes JSONL entry when M file outside whitelist exists in main checkout | leak detected -> event written |
| silent when only whitelisted M files modified (.claude/memory/**) | whitelist prefix match silence |
| silent when only whitelisted M file modified (.claude/instincts.yaml) | whitelist exact match silence |
| throttle: stops logging after 5 events per session (count increments) | throttle marker enforced |
| throttle: counter per-session (different session re-baselines) | marker keyed by session_id |

### test/smoke/auto_clean_worktree_leak_spec.bats (4)

Covers `.claude/hooks/auto_clean_worktree_leak.sh` — PreToolUse Bash
hook that fires on main-checkout sync commands
(`git pull *`, `git checkout origin/*`, `git merge origin/*`),
detects unwhitelisted M files, writes a `cleaned` event to the same
log, then `git checkout HEAD -- <files>` to restore tracked content
before the sync runs.

| Test | Scenario |
|------|----------|
| git pull with unwhitelisted M triggers checkout HEAD + cleaned log entry | trigger + clean + log all wired |
| silent when git pull but no M files at all | no-leak passthrough |
| silent when only whitelisted M (no checkout HEAD, no log) | whitelist preserved on sync |
| non-trigger command passes through (git status, git log, etc.) | matcher silence on non-sync git cmds |

### test/smoke/remind_strategic_compact_spec.bats (24)

Covers `.claude/hooks/remind_strategic_compact.sh` — Stop hook that
reads the session transcript and proposes `/compact` at task
boundaries. Signals: `gh pr merge` Bash invocation (any count > 0)
OR tool-call count reaching `STRATEGIC_COMPACT_TOOL_THRESHOLD`
(default 100). **Both counters baseline at the last `/compact`
event** (transcript `type=system && subtype=compact_boundary`
entry) so the hook stops re-firing the moment you compact;
sessions without a compact fall back to whole-session counting
(refs #170). Throttled once per session per signal-set hash.

| Test | Scenario |
|------|----------|
| silent when STRATEGIC_COMPACT_DISABLE=1 | kill switch |
| silent when stop_hook_active=true | re-entry guard |
| silent when transcript_path missing | defensive |
| silent when transcript_path unreadable | defensive |
| silent on non-Stop input shape (no transcript_path key) | defensive |
| silent on low tool-count + no PR merge | no-signal happy path |
| silent on empty transcript | edge case |
| fires on gh pr merge invocation (even with low tool count) | PR-merge signal |
| fires on tool count >= default threshold (100) | count signal |
| silent on tool count below default threshold (99 < 100) | threshold boundary |
| fires on both PR merge AND high tool count (both reasons listed) | combined signal |
| respects STRATEGIC_COMPACT_TOOL_THRESHOLD override (lower) | env override down |
| respects STRATEGIC_COMPACT_TOOL_THRESHOLD override (higher) | env override up |
| ignores non-integer threshold override (falls back to default 100) | bad-input guard |
| second fire with same signal-set is silent (throttle marker) | idempotency |
| different session id re-proposes (no false throttling across sessions) | session scoping |
| text mention of 'gh pr merge' does NOT count as signal | tool_use only |
| tool_use of a non-Bash tool with 'gh pr merge' in input does NOT count | Bash only |
| fired output omits hookSpecificOutput (Stop schema forbids it) | Stop schema regression |
| re-baselines tool_count at last compact_boundary (post-compact 0 tools = silent) | compact baseline tracer |
| fires on post-compact tool_count crossing threshold (message uses post-compact count) | post-compact count semantics |
| multiple compact_boundary entries: only counts after the LAST one | multi-compact baseline picks the last |
| re-baselines pr_merge_count at last compact_boundary | pr_merge baseline symmetry |
| type=user with subtype=compact_boundary does NOT trigger re-baseline | predicate specificity |

### test/smoke/remind_main_sync_spec.bats (23)

Covers `.claude/hooks/remind_main_sync.sh` — PreToolUse on Bash matching
`gh pr merge`. Reminds the user to `git pull --ff-only origin main` on
the main checkout after the merge lands. Two message variants by
presence of `--auto`.

| Test | Scenario |
|------|----------|
| silent on non-gh command | non-trigger |
| silent on gh pr view | read-only path |
| silent on gh pr checks | read-only path |
| silent on gh pr create | wrong subcommand |
| silent on git pull (already syncing main) | non-merge path |
| silent on empty tool_input | defensive |
| silent on non-Bash tool_input shape | defensive |
| fires immediate variant on plain gh pr merge | immediate happy path |
| fires immediate variant on gh pr merge --squash --delete-branch | typical flags |
| fires immediate variant on gh pr merge --merge | --merge flag |
| fires immediate variant on gh pr merge --rebase | --rebase flag |
| fires queued variant on gh pr merge --auto | queued message variant |
| fires queued variant on gh pr merge --auto --delete-branch --squash | --auto with extra flags |
| fires on gh pr merge with -R owner/repo | short repo flag |
| fires on gh pr merge with --repo owner/repo --auto | long repo flag + auto |
| fires when gh pr merge appears after && | chained command |
| fires when gh pr merge appears after ; | semicolon-chained command |
| fires when gh pr merge appears inside $( ... ) | command-substitution boundary |
| silent when gh pr merge is inside double-quoted commit message | substring-in-quote false-positive guard |
| silent when gh pr merge is inside single-quoted commit message | substring-in-quote false-positive guard |
| silent on grep 'gh pr merge' (search literal, not subcommand) | quoted search literal |
| silent on echo 'gh pr merge' | quoted echo argument |
| fires when gh pr merge runs alongside a commit message that also mentions it | real subcommand wins over quoted mention |

### test/smoke/check_main_fresh_before_worktree_spec.bats (14)

Covers `.claude/hooks/check_main_fresh_before_worktree.sh` — PreToolUse
BLOCKING on Bash matching `git worktree add ... main` (or
`origin/main`). Denies when local main is behind origin/main, so the
new worktree never branches from a stale base. Uses a local bare-repo
origin + clone fixture so `git fetch origin main` works without
network access.

| Test | Scenario |
|------|----------|
| silent on non-git command | non-trigger |
| silent on git status | non-worktree-add path |
| silent on git worktree list (not add) | wrong subcommand |
| silent on git worktree remove | wrong subcommand |
| silent on git worktree add branching from a tag, not main | non-main start-point |
| silent on git worktree add branching from a feature branch (no main token) | non-main start-point |
| silent on empty tool_input | defensive |
| silent (allow) when local main aligned with origin/main (main token) | aligned → allow |
| silent (allow) when local main aligned with origin/main (origin/main token) | origin/main token form |
| denies when local main is 1 commit behind origin/main (main token) | BEHIND → deny |
| denies when local main is 1 commit behind origin/main (origin/main token) | origin/main token, BEHIND |
| denies with explicit -C work-dir form | `git -C <dir>` resolution |
| denies with cd && form | `cd <dir> && git ...` resolution |
| silent when cwd is not a git repo (allow) | rule N/A → silent |

### test/smoke/verify_spec.bats (15)

Covers `.claude/scripts/verify.sh` — the unified change-complete
verification loop fronted by `/verify`. Stubs the test image's
`make lint`/`hadolint`/`test` targets via a temp `Makefile` so the
spec runs without docker; phases that hit the filesystem
(`tree-audit`, `test-md`, `doc-scan`, `diff-stats`) exercise real
paths against a temp git repo seeded by `setup()`.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| unknown arg exits 2 | flag validation |
| --phase needs a name | required-arg validation |
| unknown phase name exits 2 | phase-name validation |
| valid phases listed on bad phase name | error message lists known phases |
| --dry-run prints all phases without executing | plan-only mode |
| --dry-run with --phase narrows the plan | single-phase plan |
| single hard phase prints summary table | phase routing + summary table |
| all phases run end-to-end on a clean tree | full pipeline happy path |
| TEST.md drift reported when count mismatches | per-section drift detection |
| TEST.md drift reported when listed file missing | drift when bats file absent |
| hard-phase failure stops later phases by default | short-circuit on hard fail |
| --continue-on-fail runs later phases despite hard failure | override short-circuit |
| doc-scan flags AI attribution in changed files | doc-scan positive |
| doc-scan passes when no AI attribution present | doc-scan negative |

### test/smoke/instinct_query_spec.bats (14)

Covers `.claude/scripts/instinct-query.sh` -- queries
`.claude/instincts.yaml` for instincts matching a trigger kind + path,
or `--list` for the full table. The fixture builds a temp YAML with
5 entries exercising the supported schema (file_edit with glob,
file_edit without glob, git_commit, bash_command, file_edit with
both glob + not_glob).

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| unknown flag exits 2 | flag validation |
| missing kind exits 2 | required-arg validation |
| too many positional args exits 2 | arg cap |
| --list prints every instinct name with its kind | list mode |
| git_commit kind returns the commit-title instinct | kind match |
| kind with no matching instinct exits 1 | empty-result exit code |
| file_edit on .sh path returns shell-style + no-emoji | glob match + kind-only |
| file_edit on .py path returns only no-emoji | glob excludes |
| file_edit on Dockerfile matches glob with curly? | glob without extension |
| not_glob excludes the matching glob entry | negative glob |
| guidance bullets are printed indented | output shape |
| refs line printed when present, omitted when absent | optional field |
| missing INSTINCTS_FILE exits 2 | resolution failure |

### test/smoke/check_no_off_task_suggestions_spec.bats (11)

Covers `.claude/hooks/check_no_off_task_suggestions.sh` -- Stop hook
that scans the LAST assistant text message of the transcript for
off-task-suggestion phrases (user breaks, meals, wellness, schedule
management). Matched phrases trigger a remind `systemMessage`; the
hook never blocks (output has already been emitted by the time Stop
fires). Throttled once per session per matched phrase via TMPDIR
marker. Configurable via `NO_OFF_TASK_REMIND_DISABLE=1`. Refs #109.

| Test | Scenario |
|------|----------|
| silent on empty transcript | edge case |
| silent on clean technical message | no-match happy path |
| fires on 'stop for dinner?' | meal phrase |
| fires on 'take a break?' | break phrase |
| fires on 'need some rest?' | wellness phrase |
| fires on 'do it tomorrow?' | schedule phrase |
| case-insensitive match ('Stop For Dinner') | case folding |
| scans only LAST assistant message (earlier hits ignored) | last-message scope |
| throttled: same phrase fires once per session | idempotency |
| stop_hook_active=true skips | re-entry guard |
| NO_OFF_TASK_REMIND_DISABLE=1 skips | kill switch |

### test/smoke/remind_proactive_optimization_spec.bats (13)

Covers `.claude/hooks/remind_proactive_optimization.sh` -- Stop hook
that emits a `systemMessage` at a task boundary (`gh pr merge` invoked
OR tool-call count >= threshold) when the session has NOT already
mentioned an optimisation candidate. Throttled once per session per
signal-set via TMPDIR marker. Configurable via
`PROACTIVE_OPTIMIZATION_REMIND_DISABLE=1` and
`PROACTIVE_OPTIMIZATION_REMIND_THRESHOLD=<N>`. Pairs with
`.claude/skills/proactive-optimization/SKILL.md`. Refs #124.

| Test | Scenario |
|------|----------|
| silent on empty transcript | edge case |
| silent when no boundary signal (low tool count, no gh pr merge) | no-trigger happy path |
| fires after gh pr merge invocation with no prior optimisation mention | positive: PR-merge boundary |
| silent when session already raised an optimisation candidate | negative: prior mention |
| silent when PROACTIVE_OPTIMIZATION_REMIND_DISABLE=1 | kill switch |
| silent when stop_hook_active=true (re-entry guard) | parent-block guard |
| fires when tool-count crosses default threshold without gh pr merge | positive: tool-count boundary |
| silent when tool-count below default threshold | sub-threshold |
| custom threshold via PROACTIVE_OPTIMIZATION_REMIND_THRESHOLD | env override |
| throttle: second fire with same signal-set is silent | idempotency |
| optimisation mention regex is case-insensitive | case folding |
| silent on missing transcript_path | defensive |
| skill-ify (with hyphen) suppresses the reminder | regex variant |

### test/smoke/remind_skillification_candidates_spec.bats (16)

Covers `.claude/hooks/remind_skillification_candidates.sh` -- Stop
hook that emits a `systemMessage` when auto-detectable signals show
ad-hoc patterns worth promoting (a `/tmp/*.sh` invoked >= threshold
times, OR a parser-fallback Bash pattern repeated >= threshold times)
AND no skillification candidate was already raised in the
conversation. Throttled once per session per signal-set via TMPDIR
marker. Configurable via `SKILLIFICATION_REMIND_DISABLE=1`,
`SKILLIFICATION_TMP_THRESHOLD=<N>`,
`SKILLIFICATION_PARSER_THRESHOLD=<N>`. Pairs with
`.claude/skills/skillification-candidates/SKILL.md`. Refs #125.

| Test | Scenario |
|------|----------|
| silent on empty transcript | edge case |
| silent when no /tmp/*.sh and no parser-fallback patterns | no-trigger happy path |
| silent with 2 /tmp/*.sh invocations (below default threshold 3) | sub-threshold |
| fires after 3 /tmp/*.sh invocations | positive: tmp threshold |
| fires after 3 parser-fallback heredoc-redirect patterns | positive: parser threshold (heredoc) |
| fires after 3 cd-path-and-tool patterns | positive: parser threshold (cd+&&) |
| silent when session already raised a skillification candidate | negative: prior mention |
| silent when SKILLIFICATION_REMIND_DISABLE=1 | kill switch |
| silent when stop_hook_active=true (re-entry guard) | parent-block guard |
| custom SKILLIFICATION_TMP_THRESHOLD lowers the bar | env override |
| custom SKILLIFICATION_PARSER_THRESHOLD lowers the bar | env override |
| throttle: second fire with same signal-set is silent | idempotency |
| mention-regex case-insensitive (SKILL-IFY uppercase) | case folding |
| silent on missing transcript_path | defensive |
| non-/tmp .sh invocation does NOT count toward /tmp threshold | path discriminator |
| fires when BOTH signals cross threshold (reason lists both) | positive: combined signal |

### test/smoke/remind_parallel_when_bulk_spec.bats (18)

Covers `.claude/hooks/remind_parallel_when_bulk.sh` -- UserPromptSubmit
hook that emits a `systemMessage` when the user prompt has a bulk-work
indicator (numeric N >= threshold + plural noun, `all`/`every` + plural
noun, explicit comma-separated list with >= threshold tokens, or CJK
quantifier 全部/所有/每個 + bulk noun) AND the prompt does not
already mention parallel-Agent dispatch (`parallel`, `concurrent`,
`subagent`, `平行`, `Agent`). Throttled once per session per matched
signal via TMPDIR marker. Configurable via `PARALLEL_REMIND_DISABLE=1`
and `PARALLEL_REMIND_THRESHOLD=<N>` (default 4). Pairs with
`.claude/skills/parallel-agents/SKILL.md`. Refs #126.

| Test | Scenario |
|------|----------|
| silent on empty prompt | edge case |
| silent on small N (3 repos, below default threshold 4) | sub-threshold |
| fires on numeric N=11 repos | positive: numeric pattern A |
| fires on numeric N=4 PRs (boundary inclusive) | positive: threshold boundary |
| fires on 'all repos' (quantifier without explicit N) | positive: quantifier pattern B |
| fires on 'every PR' | positive: quantifier variant |
| fires on comma-list of >=4 repo-shaped tokens | positive: comma-list pattern C |
| silent on comma-list of only 3 tokens | sub-threshold (comma) |
| silent when prompt already mentions parallel | suppression |
| silent when prompt mentions 'subagent' | suppression alt-form |
| silent on PARALLEL_REMIND_DISABLE=1 | kill switch |
| custom PARALLEL_REMIND_THRESHOLD raises the bar | env override (numeric) |
| custom PARALLEL_REMIND_THRESHOLD also affects comma-list | env override (comma) |
| throttle: same signal fires once per session | idempotency |
| case-insensitive: 'ALL REPOS' fires | case folding |
| ordinal numbers do NOT trigger (the 4th issue) | false-positive guard |
| version-shaped numbers do NOT trigger (v0.32.0) | false-positive guard |
| CJK quantifier 所有 repo fires | CJK quantifier pattern |

### test/smoke/wait_issue_close_spec.bats (12)

Covers `.claude/scripts/wait-issue-close.sh` -- polls a GitHub issue
until it transitions to CLOSED. `gh` stubbed via PATH override. Sibling
to the `wait-pr-ci` family; new in #115.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| missing --repo exits 2 | required-arg validation |
| missing --issue exits 2 | required-arg validation |
| non-numeric --issue exits 2 | arg validation |
| unknown flag exits 2 | flag validation |
| state=OPEN keeps polling and hits max-iterations 124 | poll loop + iter cap |
| state=CLOSED exits 0 with snapshot | terminal-state success |
| CLOSED with linked PRs shows linked= field | closedByPullRequestsReferences projection |
| --on-close message printed on CLOSED | on-close emission |
| --on-close not printed while OPEN | on-close gating |
| stable OPEN across iterations emits one snapshot (dedup) | snapshot dedup |
| transition OPEN -> CLOSED emits both snapshots and exits 0 | mid-poll transition |

### test/smoke/wait_release_spec.bats (13)

Covers `.claude/scripts/wait-release.sh` -- polls `gh release list`
until a tag matching `--tag-pattern` (POSIX ERE) appears as stable (no
`-rc` substring). Sibling to `wait-issue-close.sh`; new in #115.

| Test | Scenario |
|------|----------|
| --help prints usage and exits 0 | help path |
| missing --repo exits 2 | required-arg validation |
| missing --tag-pattern exits 2 | required-arg validation |
| unknown flag exits 2 | flag validation |
| empty release list keeps polling and hits max-iterations | empty list handling |
| stable tag matching pattern exits 0 with classification | stable happy path |
| rc tag matching loose pattern emits rc snapshot then keeps polling | rc emission + keep polling |
| strict stable pattern excludes rc tag | tag-pattern filter |
| stable preferred when both stable and older rc in list | stable wins over older rc |
| --on-stable message printed after stable | on-stable emission |
| --on-rc message printed for rc tag | on-rc emission |
| rc dedup across iterations emits once | tag dedup |
| non-matching tags are ignored | tag-pattern filter |

### test/smoke/skills_canonical_layout_spec.bats (3)

Structural invariant (not a hook) asserting repo-owned skills are
canonicalised under `.agents/skills/<name>/` with a tracked symlink at
`.claude/skills/<name>` -> `../../.agents/skills/<name>`. Third-party
mattpocock skills are machine-local and deliberately not asserted.
Guards against an accidental revert to a real `.claude/skills/`
directory or a broken symlink. New in #210; see ADR-00000011.

| Test | Scenario |
|------|----------|
| every repo-owned .claude/skills/<name> is a symlink to ../../.agents/skills/<name> | symlink shape + target |
| every repo-owned skill resolves its SKILL.md through the symlink | functional reachability |
| every repo-owned skill canonical dir is a real directory under .agents/skills | canonical store is a real dir, not nested symlink |

## Integration specs

### test/integration/chain_spec.bats (3)
| Test | Scenario |
|------|----------|
| git commit with Co-Authored-By: Claude AND code-only stage fires both pre-tool hooks | `remind_no_ai_attribution` + `check_changelog_drift` both FIRE on the same input |
| gh pr create with attribution body fires both pre-tool hooks | `remind_ci_auto_merge` + `remind_no_ai_attribution` both FIRE |
| editing a Dockerfile fires only the TDD reminder, not content-scan hooks | `remind_tdd_categories` FIRE; emoji/AI-attribution/coverage-excl SILENT |

## Lint

`make -C .claude/test lint` runs `shellcheck` against every top-level
`.sh` in `.claude/hooks/` and `.claude/scripts/`. `make -C .claude/test
hadolint` lints `.claude/test/Dockerfile`. Both are part of `make -C
.claude/test check` and the CI workflow at `.github/workflows/test.yaml`.
