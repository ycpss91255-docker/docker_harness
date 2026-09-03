# CONTEXT.md

Domain knowledge and reference material for the `docker` workspace.
Companion to `CLAUDE.md` and `doc/adr/`.

## Routing rules

| Looking for... | Read | Why |
|---|---|---|
| A **standing rule** (must/never, style, workflow contract) | `CLAUDE.md` | Loaded into every session's system prompt; size-sensitive |
| **Domain knowledge** (how the system is structured, what each piece does, default values, gotchas) | This file (`CONTEXT.md`) | View on-demand; can grow without prompt-bloat cost |
| A **historical decision** (why we picked X over Y, postmortem of an incident, superseded approach) | `doc/adr/NNNNNNNN-*.md` | One file per decision; 5-section template (Date / Status / Context / Decision / Alternatives / Consequences); see ADR-00000001 for the meta-rationale |

The split is intentional: `CLAUDE.md` is the agent's working memory
contract, this file is the reference manual, and ADRs are the
incident log. New rationale should never land in `CLAUDE.md` — it
goes in an ADR. New domain knowledge should never land in `CLAUDE.md`
— it goes here.

## 1. Naming & file conventions

命名規則：**標準名字是我們的，後綴標記本機變體。**「我們的」＝隨版本
出貨或由工具產生、升級時會被取代、不逐台手改（`Dockerfile`、
`compose.yaml`、`.env`）；帶後綴的屬於使用者／現場操作者，工具不會動它
（`.env.local`，覆寫 `.env`，兩者都會進容器）。

`.env.generated` 是唯一「我們的卻帶後綴」的情況：它只用來填
`compose.yaml` 的 `${VAR}`，不會進容器（見 ADR-00000003 與 §3），後綴
標的是類別而非歸屬。此規則的理由、被否決的替代方案與遷移程序記在
`ycpss91255-docker/base#868`。

- 繁體中文 README：**`README.zh-TW.md`**（連字號，非底線）
- 英文 README：`README.md`
- Docker Compose：`compose.yaml`（非 `docker-compose.yaml`）

## 2. Container architecture

### Directory tree

The tree below records **filesystem facts only** -- paths and a
one-line description of what each repo is for. Lifecycle decision
state (which repos are active vs archive-pending vs rename-pending
vs `.base` migration-pending) lives in two stable sources of truth,
not duplicated here:

- `.claude/scripts/lib/roster.tsv` -- THE roster (refs #272). One row
  per org repo; the `fanout` column (`active` / `parked` / `n-a`)
  carries the batch-upgrade scope and each parked row's rationale,
  `mutation` the generic fanout engine's scope, `settings` the
  org-settings sync scope, `check` the required status check. The
  upgrader (`batch-base-upgrade.sh`) and the verifier
  (`check-template-versions.sh`) read the SAME call, so they cannot
  again cover different sets. It replaced four hand-kept copies, two of
  which had already diverged over `app/realsense_ros2`.
- GitHub issues opened via
  `.claude/scripts/batch-open-archive-rename-issues.sh` -- per-repo
  archive / rename / migration follow-up.

`.claude/scripts/check-claude-md-tree.sh` validates paths, not
annotations. Keeping lifecycle annotations out of this listing
removes a drift surface with no lint coverage (refs #130;
ros1_bridge precedent at base#378 / ros1_bridge#103).

```
docker/
├── agent/                    # AI Agent 容器
│   ├── ai_agent/             # All-in-one (Claude + Gemini + Codex)
│   ├── claude_code/          # Claude Code
│   ├── gemini_cli/           # Gemini CLI
│   └── codex_cli/            # Codex CLI
├── env/                      # ROS 開發環境容器
│   ├── ros_distro/           # ROS 1 multi-distro (noetic / kinetic × ros: / osrf/ros: × variants)
│   └── ros2_distro/          # ROS 2 multi-distro (humble / jazzy × ros: / osrf/ros: × variants)
├── app/                      # 應用程式容器
│   ├── ros1_bridge/          # ROS 1 ↔ ROS 2 bridge (multi-distro dispatcher + from-source catkin builder)
│   ├── urg_node_humble/      # Hokuyo URG -- ROS 2 (humble)
│   ├── urg_node_noetic/      # Hokuyo URG -- ROS 1 (noetic)
│   ├── realsense_humble/     # Intel RealSense -- ROS 2 (humble)
│   ├── realsense_noetic/     # Intel RealSense -- ROS 1 (noetic)
│   ├── sick_humble/          # SICK lidar -- ROS 2 (humble)
│   └── sick_noetic/          # SICK lidar -- ROS 1 (noetic)
├── archive/                  # 已 archive (read-only) 下游 repo 的本地 checkout, 留作參考
│   ├── ros_noetic/           # superseded by env/ros_distro (noetic-ros-base entry)
│   ├── ros_kinetic/          # superseded by env/ros_distro (kinetic-ros-base entry)
│   ├── ros2_humble/          # superseded by env/ros2_distro (humble-ros-base entry)
│   ├── osrf_ros_noetic/      # superseded by env/ros_distro (noetic-desktop-full entry)
│   ├── osrf_ros_kinetic/     # superseded by env/ros_distro (kinetic-desktop-full entry)
│   └── osrf_ros2_humble/     # superseded by env/ros2_distro (humble-desktop-full entry)
├── template/                 # 本地 checkout of ycpss91255-docker/base
├── multi_run/                # 多容器啟動工具 (獨立 repo)
├── org-profile/              # 本地 checkout of ycpss91255-docker/.github (org 首頁)
├── .github/workflows/        # docker_harness 自身 CI (test.yaml)
└── .claude/                  # Claude Code 設定
    ├── commands/             # 自訂 slash commands
    │   ├── audit.md                   # /audit — 跨 repo 健康檢查
    │   ├── batch-pr.md                # /batch-pr — 批次跨 repo PR（通用）
    │   ├── batch-base-upgrade.md  # /batch-base-upgrade — 批次升級下游 .base/ subtree（active list 目前 = env/ros_distro + env/ros2_distro,其餘 11 個 repo 在 DEFAULT_REPOS 內 comment-out 待 follow-up;名稱於 #146 由 batch-template-upgrade 改名）
    │   ├── doc-sync.md                # /doc-sync — 變更完成 checklist 對齊檢查
    │   ├── issue-check.md             # /issue-check — 掃 ycpss91255-docker org 未處理的 open issue
    │   ├── issue-fix.md               # /issue-fix <repo> [<issue_num>|all] [--dry-run] [--limit N] — auto-fix 一個或全部 open issue（合理才修，不合理留 comment）
    │   ├── new-repo.md                # /new-repo — 建立新 Docker repo
    │   ├── pr.md                      # /pr — Bug fix / 新功能 PR 流程
    │   ├── release.md                 # /release — Tag 與 release 流程
    │   ├── safe-delete.md             # /safe-delete — 用 trash 取代 rm
    │   ├── adr.md                     # /adr <slug> — 建立新 ADR (Architecture Decision Record),配 new-adr.sh + remind_adr_on_design_decision.sh Stop hook,refs #97
    │   └── verify.md                  # /verify — 變更完成 checklist 一次跑完 (shellcheck/hadolint/bats/tree/test-md/doc-scan/diff-stats)
    ├── scripts/             # 永久 helper script（被 commands / skills 呼叫）
    │   ├── batch-base-upgrade.sh            # /batch-base-upgrade 的實作（renamed from batch-template-upgrade.sh in #146）
    │   ├── batch-rename-template-to-base.sh # 一次性 #263 Phase 6 fanout：13 下游 git rm template/ + git subtree add --prefix=.base ycpss91255-docker/base.git vX.Y.Z + Dockerfile/main.yaml/README sed
    │   ├── batch-sensor-app-v0.27.sh        # 一次性 #263 sensor-app 5 repo fanout（realsense_humble/noetic、sick_humble/noetic、urg_node_noetic）：rename + Dockerfile 對齊 v0.27 layered config + SETUP_DIR (#254/#261)
    │   ├── batch-base-pr-body.template.md   # 對應 PR body 模板（envsubst 格式;renamed from batch-template-pr-body.template.md in #146）
    │   ├── batch-gitignore-fix.sh           # 一次性 .gitignore `.claude/` -> `.claude` 17 repo fanout（PR #21）
    │   ├── batch-gitignore-add-line.sh      # 通用 .gitignore 追加任意行的 17 repo fanout（PR #23）
    │   ├── batch-mutation-pr.sh             # 通用跨 repo fanout 引擎：--mutation <script> 套到每個 repo,worktree->mutate->commit->push->PR;取代 one-shot batch-*.sh sprawl(refs #169,配 [[batch-mutation-pr]] skill)
    │   ├── batch-line-edit.sh               # batch-mutation-pr 的第一個 preset:--file/--line 跨 repo append-line-if-missing,delegate 給引擎(refs #169)
    │   ├── ci-and-stamp.sh                  # 開 PR 前跑該 repo 的 local CI mirror(auto-detect: .claude/test/ci.sh→ci.sh check / justfile+.base/→just build test / justfile→actionlint + just test + just test lint),exit 0 ⟺ 全綠且 .claude/state/local-ci-pass/<sha>.ok marker 存在(單一 verdict 只 branch 一次;紅燈會刪同 sha 的 stale marker,寫不出 marker 就回非 0,refs #261);集中 marker-write 讓 enforce_local_full_ci_before_pr 對所有 repo 可滿足(refs #208/#176)。required set 由 lib/ci-required-jobs.sh 從 repo 自己的 workflow 推導(base=ci-rollup needs、docker_harness=workflow 的 ci.sh steps),每個 required job 必須被歸成 attested 或 excluded(附理由),兩份清單寫進 marker 並在 stamp 時印出;歸不了類就 exit 3 不跑不 stamp — marker 因此是「本機跑過這些」而非「GH CI 會過」,refs #272
    │   ├── batch-pr-merge.sh                # 批次 squash-merge 多個 <repo>:<pr>（接 short / full repo 名都可）
    │   ├── batch-pr-close.sh                # 批次 close 多個 <repo>:<pr>，--reason 必填（superseded-by 場景，例如 hotfix 後重 fanout 取代既有批次 PR）
    │   ├── check-template-versions.sh       # HTTPS curl 13 repo `.base/.version` 對齊檢查（release 後驗證）
    │   ├── fix-compose-copy-line.sh         # 一次性 compose.yaml COPY 路徑修正
    │   ├── fix-dockerfile-lint-lib.sh        # 通用：對 --branch 指定的 chore 分支批次 patch downstream Dockerfile 加 `COPY .base/script/docker/lib /lint/lib`（#284 sub-libs split 後 fanout 必須跑，idempotent）
    │   ├── fix-dockerfile-copy-script.sh     # 通用：對 --branch 指定的 chore 分支批次 patch downstream Dockerfile 把 `COPY *.sh /lint/` 改成 `COPY script/*.sh /lint/`（base#330 / v0.31.0 wrapper consolidation 後 root 沒有 *.sh,active 2 個下游 fanout 必須跑,idempotent）
    │   ├── check-claude-md-tree.sh          # CI lint：parse this file 的 .claude/ tree vs filesystem，drift 就 exit 1 (post-#127: just -f .claude/test/justfile tree-check passes CONTEXT.md as arg)
    │   ├── check-claude-md-ceiling.sh        # CI lint：assert CLAUDE.md 行數 + ^## 數在 ceiling 內 (defaults 240 / 20, env-overridable);refs #127
    │   ├── update-stale-pr.sh               # one-shot merge origin/main + normal push (NO rebase/force) for a PR whose base moved (BEHIND/CONFLICTING);auto-resolve worktree by branch via $WORKSPACE_DIR scan,refs #87/#221
    │   ├── auto-merge-on-green.sh           # auto-merge-on-green skill 的腳本:arm gh pr merge --auto + poll mergeStateStatus(MERGED/BEHIND→update-branch/DIRTY/FAIL/grace),refs #211
    │   ├── serial-merge.sh                  # 同 repo 多 PR 依序落地:逐一 delegate auto-merge-on-green.sh(只 arm 隊首→≤1 armed→CI O(N²)→O(N)),skip-and-continue + summary,refs #235
    │   ├── prune-merged-worktrees.sh        # 批次清掉「branch 有 MERGED PR」的 worktree + local branch(squash-merge 讓 --is-ancestor 失效,故問 gh);每個 path 自己解析所屬 repo(rev-parse --git-common-dir)後用 git -C <repo> 操作→cwd-independent,--dry-run 走同一套 resolution/validation 只跳過 mutation,refs #260
    │   ├── wait-pr-ci.sh                    # wait-pr-ci skill 的 PR-scoped polling loop（避開 Monitor parser warning）
    │   ├── wait-pr-ci-batch.sh              # 多 repo 多 PR 同一個 Monitor 的 batch 版本（取代 N 個平行 Monitor stream）
    │   ├── wait-tag-ci.sh                   # 同 skill 的 tag/branch-scoped 版本（gh run list --branch <tag>）
    │   ├── wait-issue-close.sh              # wait-gh-state 的 issue-close 版本（gh issue view --json state）;refs #115
    │   ├── wait-release.sh                  # wait-gh-state 的 release-tag 版本（gh release list --json tagName + stable/rc 分類）;refs #115
    │   ├── migrate-local-to-setupconf.sh    # 一次性 setup.conf.local -> setup.conf 17 repo 遷移（template #201 / v0.16.0；下個版本後刪除）
    │   ├── batch-license-apache.sh           # 一次性 Apache 2.0 LICENSE + CI/License badge fresh add 13 repo fanout（org-wide license alignment）
    │   ├── run-bats-in-compose.sh           # docker compose 跑 bats 包裝，避開 docker compose ... bash -c '...' 的 parser fallback
    │   ├── ci-wall-time-compare.sh          # diff CI 兩個 run id 的 per-job wall time + overall,輸出 markdown 表(CI-perf PR 用,refs #77 sub-2)
    │   ├── batch-open-archive-rename-issues.sh # 開 11 張下游 follow-up issue：7 archive(4 agent + ros1_bridge / sick_humble / sick_noetic) + 4 rename + template->.base 遷移(urg_node_*, realsense_*),idempotent 跳過 title 相同既有 issue
    │   ├── setup-memory-link.sh             # 新 clone / 換機器:建 symlink ~/.claude/projects/<encoded>/memory -> <workspace>/.claude/memory,讓 per-project memory portable + git-tracked。idempotent
    │   ├── verify.sh                         # /verify 的實作:依序跑 shellcheck/hadolint/bats/tree-audit/TEST.md drift/doc-scan/diff-stats,hard-fail 阻擋,輸出 markdown summary
    │   ├── instinct-query.sh                 # 查詢 .claude/instincts.yaml — `instinct-query.sh <kind> [path]` 印出符合 trigger 的 instincts (5 kinds: file_edit / git_commit / gh_pr_create / gh_issue_create / bash_command)，hooks/skills 用來取代 grep CLAUDE.md prose;refs #95
    │   ├── release-bump.sh                   # canonical primitive for release BUMP(release-tag.sh 的姊妹):寫 .version、把 `## [Unreleased]` 升成 `## [vX.Y.Z] - <date>` 並補回空的 Unreleased、並從 heading 清單 + origin remote **重新產生整段** compare-link block(不是 append,所以 repo 改名會自動修正、也不可能再漏);`--links-only` 只補 link(90 條 dangling reference 的 backfill 就是這一條指令)、`--check` 唯讀 drift gate、`--dry-run` 印 diff,refs #272
    │   ├── release-tag.sh                    # canonical primitive for cutting version tags;decision tree (RC / Z / Y / X bump) + .version integrity + RC CI 查詢 + RELEASE_X_BUMP_ACK 檢查;搭配 enforce_semver_tag_via_script.sh 強制 routing,refs #106
    │   ├── new-adr.sh                         # /adr 的實作:auto-number 8 位數補零,從 doc/adr/[0-9]*.md 掃 max+1,渲染 5-section 模板 (Date/Status/Context/Decision/Alternatives/Consequences),refs #97
    │   ├── check-log-helper-usage.sh           # CI lint：scan .claude/scripts/*.sh 偵測 bare printf|echo（usage() 內 + log-allow:script/start..end allowlist marker 外）為違反 lib/log.sh adoption,refs #148 M5
    │   ├── _instinct_parser.py               # instinct-query.sh 用的 stdlib-only YAML parser helper (避免 PyYAML dep 在 Alpine test image 缺失)
    │   ├── sync-doc-test-counts.sh           # doc/test/*.md generator：per-spec `### <path> (N)` heading、per-test catalogue rows、per-level `**N tests**` 與 TEST.md 索引全部從 spec tree 推導；`--check` 用同一條 code path 產生 scratch copy 再 diff（ci.sh doc-count-check / system spec 的 gate),取代手抄目錄,refs #265
    │   ├── sync-org-repo-settings.sh         # idempotent org-wide repo settings sync (fork PR approval / merge defaults / branch protection); supports --dry-run + --repo <name>; private repos skip fork-PR + protection per API constraints
    │   ├── unpublished-worktrees.sh          # sweep a worktree root for branches holding work that reached nobody: commits ahead of origin/main AND no PR in ANY state (--squash means merged branches are never ancestors, so ahead-of-main alone reports every landed worktree), gated on quiet period + clean tree; each worktree resolved against its OWN origin (no --repo flag), exact-line PR match, --watch reports once per transition; the default root is the directory a linked worktree sits in (../worktree relative to the repo root otherwise) and a root that does not exist is exit 2, never the all-clear, refs base#1003
    │   └── lib/
    │       ├── checkpoint.sh                  # /tmp checkpoint protocol helper — write_checkpoint + is_acked,Tier 2 E2 hook 共享 deny/ack 契約,refs ADR-00000002 / #117
    │       ├── log.sh                          # OTel-aligned 5-level JSON logger; mirror of ycpss91255-docker/base@v0.37.0 (script/docker/lib/log.sh),refs base#423 / base#438 / #148
    │       ├── log-events.txt                 # registered body enum for _log_*; unregistered body 觸發 fatal exit
    │       ├── log.lnav-format.json           # lnav format file for the JSON logger output
    │       ├── roster.tsv                      # THE 一份 org repo 名冊(取代先前散在 4 支 script + pr.md 的複本):欄位 repo/path/fanout(active|parked|n-a)/mutation/settings/check/note;fanout 欄同時餵 batch-base-upgrade(開 PR)與 check-template-versions(驗證),所以兩邊不可能再看不同集合,refs #272
    │       ├── roster.sh                       # roster.tsv 的唯一 reader:roster_fanout_paths/_repos <active|parked|all>、roster_mutation_paths/_repos、roster_settings_repos、roster_required_check <repo>、roster_file;純讀不改,refs #272
    │       └── ci-required-jobs.sh             # 從 repo 自己的 workflow 推導「CI 到底要求什麼」的純讀函式庫:ci_required_jobs(ci-rollup needs,flow/block 兩種 YAML seq)、ci_ci_sh_targets / ci_check_targets(docker_harness 兩邊 target 集合)、ci_actionlint_image / ci_actionlint_ignores(pin + 抑制規則);ci-and-stamp.sh 用它把 marker 的宣稱釘在 workflow 上而非手抄表,refs #272
    ├── memory/               # Claude Code per-project memory（auto-loaded via symlink）
    │   ├── MEMORY.md         # 入口索引(被 Claude Code 自動讀進 system prompt 開頭)
    │   ├── feedback_*.md     # 個別 feedback / workflow rule（每檔有 name + description + type frontmatter）
    │   └── project_*.md      # 專案性 context（如 ros1_bridge_jetson）
    ├── hooks/                # PostToolUse / PreToolUse / Stop / UserPromptSubmit hooks
    │   ├── check_no_emoji.sh           # Edit/Write 後掃 emoji
    │   ├── check_no_coverage_excl.sh   # Edit/Write 後掃 LCOV_EXCL_* 等覆蓋率忽略註解
    │   ├── check_no_ai_attribution.sh  # Edit/Write 後掃 Co-Authored-By/Generated with Claude
    │   ├── check_changelog_drift.sh    # git commit 前比對 staged code vs CHANGELOG.md
    │   ├── remind_readme_on_core_script.sh # git commit 前提醒 base 核心 .sh 改動是否同步 README
    │   ├── check_test_md_drift.sh      # *.bats / test_*.py|*_test.py / TEST.md 後比對測試數(.bats 數 @test、.py 數 def test_,refs #156/#198)
    │   ├── remind_tdd_categories.sh    # 動到 .sh/Dockerfile/compose 等時提醒 4 類測試
    │   ├── remind_ci_auto_merge.sh     # gh pr create 前提醒用 auto-merge-on-green skill(arm auto-merge + Monitor 落地);refs #211 (原 remind_pr_wait_ci)
    │   ├── remind_monitor_on_ci_trigger.sh # gh workflow run / gh run rerun 前提醒用 wait-tag-ci.sh / /wait-pr-ci (refs #154)
    │   ├── remind_monitor_on_git_push.sh # git push re-push/force-push 既有 PR branch（非 -u、非 main、非 tag）時提醒對同 PR re-invoke /wait-pr-ci(完成 CI-watch umbrella,refs #157)
    │   ├── remind_no_ai_attribution.sh # git commit / gh pr create 前掃 inline 歸屬字串
    │   ├── remind_docker_for_lint.sh   # bats/shellcheck/hadolint/kcov 前提醒走 Docker (wrapper list 可被 .claude/lint_wrappers.txt override)
    │   ├── remind_no_heredoc_redirect.sh # cat <<EOF > file 時提醒用 Write 工具
    │   ├── remind_no_chinese_in_git_artifacts.sh # git commit / gh PR / issue title|body|comment 前 BLOCK CJK 與全形字符
    │   ├── enforce_gh_body_file.sh     # gh issue/pr create/edit/comment/close/review 前 BLOCK 違反 body-file 規律的 8 種 pattern(配合 [[gh-artifact-format]] skill,refs #64)
    │   ├── remind_test_tools_smoke_sync.sh # Dockerfile.test-tools 改動但同層 release-test-tools.yaml 未同步時提醒
    │   ├── auto_allow_rm_in_workspace.sh # rm <workspace+/tmp 內 path> 自動 allow（避開 Bash(rm:*) ask yes-fatigue）
    │   ├── auto_allow_touch_ack.sh       # touch $TMPDIR/claude-checkpoint-*.ack 自動 allow（/tmp checkpoint 協定一鍵 ack,refs ADR-00000002 / #117）
    │   ├── check_tag_version_consistency.sh # git tag/push v* 前 BLOCK：repo root 有 .version 且不等於 tag 則 deny（refs #36；defensive 第二層,主要 gate 由 enforce_semver_tag_via_script.sh 接手）
    │   ├── enforce_semver_tag_via_script.sh # git tag/push v* 前 BLOCK：raw 命令一律拒絕,強制走 .claude/scripts/release-tag.sh canonical script(refs #106)
    │   ├── enforce_wrapper_first_upgrade.sh # 三個 surface (./.base/upgrade.sh / ./template/upgrade.sh / git subtree pull --prefix=.base|template) 前 BLOCK,改走 hook 偵測的 wrapper(root justfile 有 upgrade recipe→just upgrade;過渡期的 justfile.ci / Makefile.ci 已退役不再視為 wrapper,checkpoint ack 可解,refs #36 / #280 / ADR-00000002 / base#573 / #202)
    │   ├── enforce_batch_via_script.sh   # 跨 repo for-loop + mutation (git push|reset|tag|branch -D / gh issue|pr close|merge|comment --body) 前 BLOCK,改走 .claude/scripts/<name>.sh(checkpoint ack 可解,refs #121 / ADR-00000002)
    │   ├── enforce_serial_merge_gate.sh  # `gh pr merge ... --auto` 第 2+ 個同 repo arm 前 BLOCK：查 `gh pr list --json number,autoMergeRequest` 已 armed >=1 就 deny + 印 ready-to-paste `.claude/scripts/serial-merge.sh <repo> <armed...> <this>`,避免 strict branch protection 下 O(N^2) CI re-run;0 armed 放行、SERIAL_MERGE=1 或 checkpoint ack 可 bypass(refs #236 / #235 / ADR-00000002)
    │   ├── enforce_worktree_for_branch.sh # 主 checkout 內 git checkout -b|-B 前 BLOCK,要求改走 git worktree add <path> -b <branch> main(內部 worktree 自動放行,checkpoint ack 可解,refs #122 / PR #89 / ADR-00000006)
    │   ├── enforce_merge_update_not_rebase.sh # git rebase(除 --abort/--continue/--skip)+ 有 open PR 的 branch force-push 前 BLOCK,改走 git merge origin/main + 一般 push;no-PR force-push / gh 錯誤 fail-open,checkpoint ack 可解,refs #221
    │   ├── enforce_local_full_ci_before_pr.sh # gh pr create/ready 前 BLOCK：HEAD 無 local-CI marker(.claude/state/local-ci-pass/<sha>.ok,由 .claude/test/ci.sh test 綠時寫)且非「綠後只動 doc」則 deny;LOCAL_CI_ACK=<sha> 可 override(refs #176)
    │   ├── enforce_scripts_tracked_before_pr.sh # gh pr create/ready 前 BLOCK：.claude/scripts/ 下(含 lib/)還有 untracked *.sh 就 deny 並列出檔名 — enforce_batch_via_script 只管「產生」不管「善後」,15 個 fanout 一次性腳本累積成 local lint 長紅的根因;放 PR-open 而非 ci.sh check,因為腳本寫到一半未 commit 是合法中間狀態(refs #282)
    │   ├── check_prefer_dot_sh.sh       # docker build/run/exec/stop/compose 前：cwd 有對應 .sh wrapper 則 deny,沒有則 ask
    │   ├── remind_topics_yaml_on_new_repo.sh # gh repo create ycpss91255-docker/* 前提醒去 .github topics.yaml 加 repos.* 條目
    │   ├── auto_clean_worktree_leak.sh  # PreToolUse Bash：git pull / git checkout origin/* / git merge origin/* 前掃 main checkout 非 whitelist M(`.claude/instincts.yaml` + `.claude/memory/**`)→ 寫 cleaned event 到 ~/.claude/log/worktree-leak-events.jsonl + git checkout HEAD -- <files> 還原後放行；refs #167
    │   ├── check_readme_framework.sh    # Edit/Write 後掃下游 repo README.md (+ 3 翻譯) 是否符合 .base/README.md 框架(badge / 4 語言 link / TL;DR H2 / Smoke Tests link / 無 stale 路徑) — non-blocking warning
    │   ├── check_no_stale_template_refs.sh # Edit/Write 後掃 .base/ 下 .sh/Makefile/Dockerfile 是否殘留 template/<path> 引用(rename 後遺漏,refs base#282)
    │   ├── remind_main_sync.sh         # gh pr merge 前提醒 merge 後跑 git pull --ff-only origin main 保持本地 main 持續 ff-tracking origin/main HEAD
    │   ├── check_main_fresh_before_worktree.sh # git worktree add ... main 前 BLOCK：若 local main 落後 origin/main 就 deny + 提示先 pull,避免從 stale base 起 branch(refs PR #89 precedent)
    │   ├── forensic_worktree_leak.sh   # Stop hook：scan main checkout 非 whitelist M(`.claude/instincts.yaml` + `.claude/memory/**`)，發現就寫 detected event 進 ~/.claude/log/worktree-leak-events.jsonl，每 session throttle 5 次；累積 evidence 之後再追 root cause；refs #167
    │   ├── remind_strategic_compact.sh # Stop hook：讀 transcript 偵測 task-boundary 訊號(gh pr merge / tool count >= 50)後 propose /compact,configurable via STRATEGIC_COMPACT_{DISABLE,TOOL_THRESHOLD};refs #92
    │   ├── remind_adr_on_design_decision.sh # Stop hook：transcript 掃 rationale 關鍵字 (alternative/trade-off/rejected because/...) 達 threshold 且 session 無 doc/adr/ 寫入時提案 /adr,configurable via ADR_REMIND_{DISABLE,THRESHOLD};refs #97
    │   ├── check_no_off_task_suggestions.sh # Stop hook：transcript 掃 last assistant message 的 off-task 片語 (stop for dinner / take a break / need rest / do it tomorrow ...) 命中時 remind,never block,configurable via NO_OFF_TASK_REMIND_DISABLE;refs #109
    │   ├── remind_proactive_optimization.sh # Stop hook：task-boundary 訊號(gh pr merge / tool count >= 50)後若 session 未提任何 optimisation 候選 (workflow ergonomics / cross-repo inconsistency / doc drift / manual repetition) 則 remind 配 [[proactive-optimization]] skill,configurable via PROACTIVE_OPTIMIZATION_REMIND_{DISABLE,THRESHOLD};refs #124
    │   ├── remind_skillification_candidates.sh # Stop hook：偵測 /tmp/*.sh 反覆呼叫 (>=3 次) 或 parser-fallback Bash pattern 重複 (>=3 次) 且 session 未提任何 skillification 候選時 remind 配 [[skillification-candidates]] skill,configurable via SKILLIFICATION_REMIND_DISABLE + SKILLIFICATION_{TMP,PARSER}_THRESHOLD;refs #125
    │   ├── remind_parallel_when_bulk.sh # UserPromptSubmit hook：scan user prompt 偵測 bulk-work 訊號 (N >= 4 + plural noun / all|every + noun / 逗號分隔 4+ tokens / CJK 量詞) 且 prompt 未提 parallel/agent 時 remind 配 [[parallel-agents]] skill,configurable via PARALLEL_REMIND_{DISABLE,THRESHOLD};refs #126
    │   ├── remind_log_helper.sh        # PostToolUse hook：Edit/Write .claude/scripts/*.sh 後 delegate 到 check-log-helper-usage.sh,若該檔案有 bare printf|echo (usage()/allowlist marker 外) 則 systemMessage nudge 提醒走 _log_*,refs #148 M5
    │   └── warn_structured_data_text_tools.sh # PreToolUse hook：bash 指令用 awk/sed 處理 .json/.jsonl 且無 jq 時 systemMessage nudge 改用 jq / Grep 工具(line-oriented 解析 JSONL 會誤計);non-blocking,配 structured-data-use-jq instinct
    ├── skills/                         # repo-owned; each a symlink -> ../../.agents/skills/<name>/ (third-party mattpocock skills machine-local, omitted; ADR-11)
    │   ├── auto-merge-on-green/SKILL.md # 開 PR 後落地單一 PR:arm GitHub auto-merge + Monitor 包 auto-merge-on-green.sh,配 remind_ci_auto_merge hook;refs #211
    │   ├── update-stale-pr/SKILL.md    # PR BEHIND/CONFLICTING 時 merge origin/main + 一般 push(不 rebase/force)的 one-shot 流程,配 update-stale-pr.sh + wait-pr-ci FAIL hint,refs #87/#221
    │   ├── wait-pr-ci/SKILL.md         # PR CI 等待用 Monitor 而非 sleep 輪詢
    │   ├── gh-artifact-format/SKILL.md # gh issue/pr artifact 格式規範(issue title/body 5 sections/close 3 tiers/comment 3 categories/cross-ref keywords)配 enforce_gh_body_file.sh hook
    │   ├── semver-bump/SKILL.md        # 版本 tag 流程:X/Y/Z 分類 + RC 程序 + RELEASE_X_BUMP_ACK 使用,配 release-tag.sh + enforce_semver_tag_via_script.sh,refs #106
    │   ├── strategic-compact/SKILL.md  # 何時手動 /compact (task boundary) vs 何時別 compact (mid-implementation),配 remind_strategic_compact.sh hook
    │   ├── wait-gh-state/SKILL.md      # 非 CI 的 GitHub state 監看 (issue close / release stable),sibling to wait-pr-ci;refs #115
    │   ├── proactive-optimization/SKILL.md # 任務 boundary 時主動提 optimisation 候選 (workflow ergonomics / cross-repo inconsistency / doc drift / manual repetition),配 remind_proactive_optimization.sh Stop hook;refs #124
    │   ├── skillification-candidates/SKILL.md # 任務 wrap-up 時提 skillification 候選 (/tmp/*.sh re-use / parser-fallback / slash-command gap / bug-in-skill),配 remind_skillification_candidates.sh Stop hook;refs #125
    │   ├── parallel-agents/SKILL.md    # bulk workload (N>=4 獨立 items) 時用最多 3 個 parallel Agent 並行 (single response 內多 Agent 呼叫),配 remind_parallel_when_bulk.sh UserPromptSubmit hook;refs #126
    │   └── batch-mutation-pr/SKILL.md  # generic batch-mutation-PR 引擎 (跨 repo fan-out line edits),配 batch-mutation-pr.sh + batch-line-edit.sh preset;refs #169/#207
    ├── test/                           # docker_harness 自己的 hook 測試 infra（與下游 repo 的 Dockerfile 無關）
    │   ├── Dockerfile                  # bats 1.11 + shellcheck on Alpine（COPY .claude/hooks/ + .claude/scripts/ + .claude/test/）
    │   ├── bats/                       # ISTQB 測試 specs — unit/integration/system/acceptance + lib/test_helper.bash（見 doc/test/,ADR-00000013）
    │   ├── ci.sh                       # CI runner driver — both CI (.github/workflows/test.yaml) 與 local justfile 都呼叫；targets build / test / lint / hadolint / check / tree-check / ceiling-check / log-helper-check / doc-count-check / clean;lint 的檔案清單由 host 上的 lint_targets()(git ls-files)算出再交給 container,所以 local(掛 live worktree,refs #214)與 CI(clean checkout)蓋同一組 tracked *.sh,refs #282
    │   └── justfile                    # local just wrapper：just -f .claude/test/justfile <target> 轉呼 ci.sh <target>
    ├── settings.json                   # hooks 註冊 + permissions + sandbox（**唯一一份,無 settings.local.json**）
    └── instincts.yaml                  # 結構化 repo conventions (#95 pilot) — hooks/skills/commands 用 `instinct-query.sh` 查詢,取代 CLAUDE.md prose grep
```

The `.claude/` block above is the audit target for `just -f .claude/test/justfile tree-check`
(`.claude/scripts/check-claude-md-tree.sh`; CI runs the same
`.claude/test/ci.sh tree-check` driver); drift between this listing and
the filesystem fails the build. Post-#127 the tree-check target invokes the script
with this file as the argument; pre-#127 it read `CLAUDE.md`.

### Standard container layout

每個容器目錄遵循相同的檔案配置模式：

```
<repo>/
├── Dockerfile                   # 多階段建置
├── compose.yaml                 # Docker Compose 服務定義
├── build.sh -> .base/script/docker/build.sh   # symlink
├── run.sh -> .base/script/docker/run.sh       # symlink
├── exec.sh -> .base/script/docker/exec.sh     # symlink
├── stop.sh -> .base/script/docker/stop.sh     # symlink
├── Makefile -> .base/script/docker/Makefile    # symlink
├── .hadolint.yaml -> .base/.hadolint.yaml      # symlink（或自訂版本）
├── script/
│   └── entrypoint.sh            # 容器進入點
├── doc/
│   ├── README.zh-TW.md          # 繁體中文
│   ├── README.zh-CN.md          # 簡體中文
│   ├── README.ja.md             # 日文
│   ├── test/TEST.md             # 測試文件
│   └── changelog/CHANGELOG.md   # 變更記錄
├── test/
│   └── smoke/
│       └── <name>_env.bats      # Bats 環境測試（repo-specific）
├── .base/                    # git subtree（共用腳本、測試、設定；版本追蹤檔 .base/.version）
├── config/docker/setup.conf     # （選用）repo override；section-replace .base/config/docker/setup.conf（路徑自 #262 / v0.25.0 起）
├── .env.example                 # IMAGE_NAME fallback
├── .gitignore
├── .github/workflows/
│   └── main.yaml                # CI/CD（呼叫 base 的 reusable workflows）
└── README.md                    # 英文（根目錄，GitHub 自動顯示）
```

> **注意**：共用的 smoke tests（script_help.bats、display_env.bats、test_helper.bash）
> 位於 `.base/test/smoke/`，不放在 `test/smoke/`。
> Dockerfile 用兩行 COPY 合併：
> ```dockerfile
> COPY .base/test/smoke/ /smoke_test/
> COPY test/smoke/ /smoke_test/
> ```
> `display_env.bats` 會自動偵測 compose.yaml 是否有 GUI 設定，headless repo 自動 skip。

### `.base` subtree structure

```
.base/
├── init.sh                       # 初始化 repo（新建或既有）
├── upgrade.sh                    # 升級 .base/ subtree 版本
├── setup.conf                    # 預設設定（image_name/gpu/gui/network/volumes）
├── script/
│   ├── docker/                   # Docker 操作腳本（各 repo symlink）
│   │   ├── build.sh
│   │   ├── run.sh
│   │   ├── exec.sh
│   │   ├── stop.sh
│   │   ├── setup.sh              # .env + compose.yaml 產生器（讀 setup.conf）
│   │   ├── i18n.sh               # 語言偵測
│   │   └── Makefile
│   └── ci/
│       └── ci.sh                 # CI pipeline（本地 + 遠端）
├── dockerfile/
│   ├── Dockerfile.test-tools     # 預建置測試工具 image
│   └── Dockerfile.example        # 新 repo 的 Dockerfile 範本
├── config/                       # Shell 設定（bashrc、tmux、terminator、pip）
├── test/
│   ├── smoke/                    # 共用 smoke tests
│   ├── unit/                     # template 自身測試（見 doc/test/TEST.md）
│   └── integration/              # init.sh 整合測試（見 doc/test/TEST.md）
├── justfile                      # template CI 入口
├── compose.yaml                  # Docker CI 執行器
└── .hadolint.yaml                # 共用 Hadolint 規則
```

### User & permission management

Dockerfile 接受 `USER_NAME`、`USER_UID`、`USER_GID` 參數，在容器內建立
與主機 UID/GID 相符的用戶。sys stage 處理 UID/GID 衝突。

### Multi-stage build conventions

- `bats-src` / `bats-extensions` / `lint-tools` stage：測試工具來源（不出貨，可用 `test-tools:local` 替代）
- `sys` stage：用戶/群組建立、sudo 設定、時區語系、APT mirror 設定
- `base` stage：開發工具與語言套件
- `devel` stage：應用專屬工具 + entrypoint + PlotJuggler（env repos）
- `test` stage：ShellCheck → Hadolint → Bats smoke test（短暫性，build 完即丟）
- `runtime` stage：（僅應用程式類型）最小化 runtime
- Shell 設定：`SHELL ["/bin/bash", "-x", "-euo", "pipefail", "-c"]`

## 3. Setup pipeline (`setup.conf` → `.env` + `compose.yaml`)

`setup.sh` 讀取 `setup.conf`（INI 格式設定）+ 系統偵測 → 產生 `.env` 與
`compose.yaml` 兩份 derived artifacts。來源是 `setup.conf`，不要直接手改
`.env` / `compose.yaml`（下次 build/run 會被覆蓋）。

**每次 `build.sh` / `run.sh` 預設都會重新產生 `.env` + `compose.yaml`**，
使用 `--no-env` 跳過。`setup.sh` 會保留既有 `.env` 中有效的 `WS_PATH`、
`APT_MIRROR_*`。

### `setup.conf` location & override strategy

- `.base/config/docker/setup.conf` — 模板預設值（4 個 section；路徑自 #262 / v0.25.0 起）
- `<repo>/config/docker/setup.conf` — 選用 repo override。**Section-replace**：
  repo 檔有的 section 完整取代模板該 section；repo 沒列的 section
  繼續用模板預設

### `setup.conf` section schema

| Section | Key | 意義 |
|---------|-----|------|
| `[image_name]` | `rules` | IMAGE_NAME 偵測規則（有序，逗號分隔）：`@env_example`、`prefix:xxx`、`suffix:xxx`、`@basename`、`@default:xxx` |
| `[gpu]` | `mode` | `auto`（偵測 nvidia-container-toolkit） / `force` / `off` |
| `[gpu]` | `count` | `all` 或整數 |
| `[gpu]` | `capabilities` | 空格分隔：`gpu` / `compute` / `utility` / `graphics` |
| `[gui]` | `mode` | `auto`（偵測 `$DISPLAY`/`$WAYLAND_DISPLAY`） / `force` / `off` |
| `[network]` | `mode` | `host` / `bridge` / `none` |
| `[network]` | `ipc` | `host` / `shareable` / `private` |
| `[network]` | `privileged` | `true` / `false` |
| `[volumes]` | `mount_1..N` | 額外掛載，`<host>:<container>[:ro\|rw]`；含 `/dev/*` 裝置 pass-through。按數字後綴排序 |

### System-detected items (do not read `setup.conf`)

- 使用者資訊：UID/GID/USER/GROUP（`id`）
- 硬體架構：`uname -m`
- Docker Hub 用戶
- WS_PATH 工作區三策略偵測：同層掃描 → 向上遍歷 → 退回上層目錄
- APT_MIRROR_UBUNTU / APT_MIRROR_DEBIAN：預設台灣鏡像，保留既有值

### Drift detection

`setup.sh` 在 `.env` 中寫入 `SETUP_*` metadata（包含 `SETUP_CONF_HASH`，
SHA256 over 模板 + repo setup.conf）。build/run 會比對 hash，若 setup.conf
已變動會自動重跑；使用者手改 .env 不會觸發重跑，但會在下次不帶 `--no-env`
時被蓋掉。

### `compose.yaml` conditional blocks

`generate_compose_yaml` 依 `[gpu]`/`[gui]` resolve 結果條件組裝：
- GPU 啟用 → 輸出 `deploy.resources.reservations.devices`（`nvidia` + count + capabilities）
- GUI 啟用 → 輸出 DISPLAY / WAYLAND / XDG_RUNTIME_DIR / XAUTHORITY 的 env + volume
- 基線 volumes 永遠輸出（`${WS_PATH}:/home/${USER_NAME}/work`），`[volumes] mount_*` 加在其後

## 4. Subtree mechanics (`.base/` upgrade flow)

```bash
# 1. 在 base 本體修改 + commit + push + tag (use latest version)
# Note: 本地 checkout 仍叫 `template/` (尚未 rename),只是 GitHub 端 repo 改名為 base
cd template && git push && git tag -a vX.Y.Z -m "vX.Y.Z: ..."
git push origin vX.Y.Z

# 2. 各 repo 跑 just upgrade（內部呼叫 upgrade.sh，自動處理 subtree pull
#    + integrity check + init.sh symlink resync + main.yaml @tag sed）
cd <repo>
just upgrade vX.Y.Z                          # 指定版本（推薦；下游 consumer）
# 或 just upgrade                            # 升到最新 tag
# base 自身無 upgrade recipe：它是來源端,不從別處升級
# Fallback（wrapper 不可用時，被 hook 擋需 ACK）: ./.base/upgrade.sh vX.Y.Z

# 3. 走 PR merge（branch protection 禁止直接 push main）
git push origin <branch> && gh pr create
```

**升級一律 make 優先，`./.base/upgrade.sh` 留作 fallback**（沒有 make、
或 make target 出問題時才用）。**不要手動 `git subtree pull`** —
`upgrade.sh` 的 init.sh resync 與 `main.yaml` sed 很容易漏；版本追蹤用
subtree 內 `.base/.version`（不是已移除的 root `.template_version` /
`VERSION`）。下游 repo 若要自動升 PR 可加 `.github/dependabot.yml` 監
`github-actions` ecosystem（snippet 見 template README「Updating」章節）。

## 5. CI/CD

### Reusable workflows

所有 repo 使用 `template` 提供的 **reusable workflows**，各 repo 只保留 `main.yaml`：

```
main.yaml
├── call-docker-build → .base/.github/workflows/build-worker.yaml@<version>
│   inputs: image_name, build_args, build_runtime
└── call-release → .base/.github/workflows/release-worker.yaml@<version>
    inputs: archive_name_prefix, extra_files
```

- `build.sh` 會先 build `test-tools:local` image（ShellCheck + Hadolint + Bats）
- Dockerfile `test` stage 依序執行：ShellCheck (.sh) → Hadolint (Dockerfile) → Bats smoke test
- `call-release` 需要 build 通過才觸發，僅 `v*` tag 觸發
- `.hadolint.yaml` 忽略不適用於 dev 環境的規則（DL3007/DL3008 等）
- 本地 `./build.sh test` 與 CI 執行完全相同的檢查

### Smoke Tests link convention

所有 repo 的 README Smoke Tests section 簡化為連結到 TEST.md：
```markdown
## Smoke Tests

See [TEST.md](doc/test/TEST.md) for details.
```

### CI 監控 (PR open 後)

開完 PR 後不要用 `sleep` 輪詢、也不要反覆手動跑 `gh pr checks`。改用
**`wait-pr-ci` skill**（`.claude/skills/wait-pr-ci/SKILL.md`）— 內部以
Monitor 工具 + `until` poll loop 30s 間隔，每個 check 從 pending 變化時
噴一行通知，全部 settle 後噴 `ALL_DONE`，agent 不會被 sleep 卡住、
context 也不會被 polling output 噴爆。

適用情境：
- 剛開完 PR 等 merge
- 同 batch 多個 PR 平行等
- `@dependabot rebase` 後 CI 重跑

不適用 tag-triggered workflow（release-test-tools / release-worker）—
那是 tag-scoped 不是 PR-scoped，套同樣 Monitor pattern 但改查
`gh run list --branch <tag>`。

skill 內含 status check filter 對應表（template / docker_harness /
單 distro 容器 / multi-distro env / multi-distro app / .github），
詳見 SKILL.md。

## 6. Versioning & release

### SemVer X/Y/Z semantics (2026-05-15 update, refs #106)

| 位 | 用途 | RC 要求 | 額外 gate |
|---|---|---|---|
| **X (MAJOR)** | Ceremonial / 主要 release marker — 跟「破壞性變更」**解綁** | 必須 | **User 明確同意**（`RELEASE_X_BUMP_ACK=<tag>` env） |
| **Y (MINOR)** | 功能調整 + 破壞性變更（任何 user-visible 非 bug-fix 變動） | 必須 | 無 |
| **Z (PATCH)** | Bug 修復（純修補 / 文件修正） | 不用 | 無 |
| `MAJOR.MINOR.0-rcN` | Release Candidate（正式發布前驗證） | n/a | 隨時可 cut |

舊規則（X = 破壞性）已淘汰；現在 breaking 跟 non-breaking feature 一起
落 Y，X 純粹由 user 在 chat 明確說「OK cut」才動。

**Bump 走 `.claude/scripts/release-bump.sh`,tag 走 `release-tag.sh`** — 兩支
是同一個 release 的兩半。bump 那半以前只是 `release.md` 裡的散文(手工做過
106 次),結果 Keep-a-Changelog 的 compare-link block 停在 `[v0.6.8]`:106 個
version heading 只有 16 條 link 定義,約 90 個 heading 變 dangling reference,
而僅存的 16 條還指著改名前的 `.../template/...`。release-bump.sh 每次都從
heading 清單 + `origin` remote **重新產生整段 link block**,所以 backfill 與
防再腐化是同一個動作;`--check` 是唯讀 gate(refs #272)。

**強制走 `.claude/scripts/release-tag.sh`** — `enforce_semver_tag_via_script.sh`
PreToolUse hook BLOCKs raw `git tag v*` / `git push.*v[0-9]`，迫使 caller
透過 canonical script。Script 內含 decision tree + RC CI 查詢 + ACK 檢查 +
`.version` integrity。配對的 `[[semver-bump]]` skill 詳列 X/Y/Z 程序
（CLAUDE.md 的 release section 是 standing rule pointer，這裡只列語意
細節，不複製 step-by-step 流程）。

### Release flow

```bash
# 1. 打 RC tag（GitHub Release 自動標為 prerelease）
.claude/scripts/release-tag.sh v1.3.0-rc1 -m "v1.3.0-rc1: ..."

# 2. 等 CI 全部通過（wait-tag-ci skill）
.claude/scripts/wait-tag-ci.sh --repo ycpss91255-docker/<repo> --branch v1.3.0-rc1

# 3. RC 通過 → 打正式 tag
.claude/scripts/release-tag.sh v1.3.0 -m "v1.3.0: ..."

# 4. RC 失敗 → 修復後打 rc2（never re-tag 同 rcN）
.claude/scripts/release-tag.sh v1.3.0-rc2 -m "v1.3.0-rc2: fix ..."

# 5. X bump (v1.0.0 / v2.0.0) 額外需要 user 在 chat 明確 OK
#    Claude 不能自己加 RELEASE_X_BUMP_ACK，必須等 user 說「ok cut v1.0.0」
RELEASE_X_BUMP_ACK=v1.0.0 .claude/scripts/release-tag.sh v1.0.0 -m "v1.0.0: ..."
```

> `release-worker.yaml` 已設定 `prerelease: ${{ contains(github.ref_name, '-') }}`，tag 含 `-` 會自動標為 prerelease。
>
> Z bump（bug fix）直接 `release-tag.sh v1.3.1 -m "v1.3.1: ..."` 無 RC。
> 詳見 `.claude/skills/semver-bump/SKILL.md`。

## 7. i18n (script message localisation)

腳本訊息支援 4 種語言：`en`（預設）、`zh`（繁中）、`zh-CN`（簡中）、`ja`（日文）。

| 元件 | i18n 方式 | 切換方法 |
|------|----------|---------|
| `setup.sh`（template） | `_msg()` 函式 | `--lang` flag 或 `SETUP_LANG` 環境變數 |
| `build.sh` / `run.sh` | usage() case 分支 + 轉發 `--lang` 給 setup.sh | `--lang` flag 或 `SETUP_LANG` 環境變數 |
| `exec.sh` / `stop.sh` | usage() case 分支 | `SETUP_LANG` 環境變數 |
| README | 各語言獨立檔案放在 `doc/` | 頂部語言切換連結 |

### Shell script conventions

- 所有 `.sh` 使用 `set -euo pipefail`
- Help 統一使用 `usage()` 函式 + `cat >&2`
- 所有互動腳本（build.sh / run.sh / exec.sh / stop.sh）支援 `-h` / `--help`
- build.sh / run.sh 支援 `--lang` 旗標
- ShellCheck compliant（CI 強制）

## 8. Defaults (locale / timezone / APT / GPU / GUI)

### Locale (important — order matters on Debian bookworm)

Debian bookworm 必須先 uncomment `/etc/locale.gen` 再 `locale-gen`，
`LC_ALL`/`LANG` ENV 必須在 `locale-gen` **之後**設定：

```dockerfile
RUN sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && \
    locale-gen && \
    update-locale LANG="en_US.UTF-8"

ENV LC_ALL="en_US.UTF-8"
ENV LANG="en_US.UTF-8"
```

### Timezone & locale

所有容器預設使用 `Asia/Taipei` 時區與 `en_US.UTF-8` 語系。

### APT mirror

`setup.sh` 產生的 `.env` 包含 APT mirror 設定：
- `APT_MIRROR_UBUNTU=tw.archive.ubuntu.com`
- `APT_MIRROR_DEBIAN=mirror.twds.com.tw`

Dockerfile 透過 `ARG` + `sed` 使用，`|| true` 防止檔案不存在時失敗。

### GPU support

AI Agent 容器透過 `devel-gpu` service 支援 NVIDIA GPU（CPU 為預設）。
`post_setup.sh` 偵測 GPU 後設定
`BASE_IMAGE=nvidia/cuda:13.1.1-cudnn-devel-ubuntu24.04`。ROS 環境容器
透過 compose.yaml 的 `deploy.resources.reservations.devices` 設定。

## 9. AI Agent credential isolation

只掛載**憑證檔案**，不掛載整個設定目錄：
- Claude：`~/.claude/.credentials.json`
- Gemini：`~/.gemini/oauth_creds.json`
- Codex：無 OAuth 檔案，僅使用 `OPENAI_API_KEY`

## 10. Branch protection (per-repo `required_status_checks`)

所有 `ycpss91255-docker` 組織下的 repo，main branch 一律啟用 branch
protection，**包含 admin**，任何情境都不允許直接 push：

| 設定項 | 值 | 說明 |
|--------|------|------|
| `required_pull_request_reviews` | 啟用，0 approver | 必須透過 PR，但不要求 review approval |
| `required_status_checks` | strict=true | 必須通過 CI 才能 merge |
| `enforce_admins` | **true** | admin 也不能 bypass，一律走 PR |
| `allow_force_pushes` | false | 禁止 force push |
| `allow_deletions` | false | 禁止刪除 protected branch |

Status check 名稱依 repo 類型不同：

| Repo 類型 | Status Check Context |
|-----------|---------------------|
| `template` (base) | `ci-rollup`（self-test.yaml aggregator，post-#337） |
| `multi_run` | `test` |
| `docker_harness`（本 repo） | `bats + shellcheck + hadolint`（單 job test workflow） |
| 單 distro 容器 repo（多數 `agent/*`、`app/*`） | `call-docker-build / docker-build` |
| Multi-distro env repo（`env/ros_distro`、`env/ros2_distro`） | `ci-passed`（matrix aggregator） |
| Multi-distro app repo（`app/ros1_bridge` post-#54） | `ci-summary`（in-repo aggregator） |
| `.github`（組織首頁，post-topics-taxonomy） | `lint`（yaml 結構驗證 + shellcheck） |

新建 repo 時必須同步設定 branch protection，`/new-repo` slash command
應自動處理。

## 11. TDD test taxonomy (ISTQB three-axis)

所有變更採嚴格 TDD：先寫失敗測試 → 寫最少程式碼讓測試通過 → 重構。
測試分類對齊 ISTQB（ADR-00000013；base 端 ADR-00000018），三個正交軸：
**levels**（範圍）、**types**（用途）、**static analysis**（lint）。取代
舊的 4-category（smoke/unit/integration/lint）混軸模型。

### 軸 1 — 靜態分析（static analysis）

Lint：ShellCheck（所有 `.sh`）+ Hadolint（Dockerfile）。不是動態測試
level。base 住 `test/lint/<tool>/`；CI 強制。

### 軸 2 — Levels（範圍階梯）

| Level | 範圍 | 本專案位置 / 工具 |
|-------|------|------------------|
| Unit（Component） | 隔離單一函式 / 腳本 | base `test/bats/unit/`；docker_harness `.claude/test/bats/unit/`（每個 hook 隔離觸發）|
| Integration | 多元件協同（init / upgrade / dispatch、多 hook 同一 input） | base `test/bats/integration/`；docker_harness `.claude/test/bats/integration/` |
| System | 整個 built image 端到端（build→run→exec→stop）、build-gate 機制 | base `test/bats/system/`；docker_harness `.claude/test/bats/system/`（框架自我結構稽核）|
| Acceptance | 下游 consumer 收到的（scaffold 框架 + UX；UAT/OAT） | base `test/bats/acceptance/`；docker_harness `.claude/test/bats/acceptance/`（settings/skills 完整性）|

頂層是 **System**（ISTQB）。「End-to-end」是在 System/Acceptance level
執行的一種 *type*，不是 level 名稱。

### 軸 3 — Types（用途；套在某個 level 上）

- **Smoke** — build-verification：「容器起不起得來」的關鍵子集，在每個
  Dockerfile `-test` stage build 時跑。**docker_harness 無產品 image → N/A**。
- **End-to-end** — 完整流程頭到尾。
- **Regression** — 守住已修的 defect（如 build-gate-fires，前身 `behavioural`）。

### 變更類型 → 應該寫哪些測試（level / type + static）

| 變更內容 | Level（含 type） | Static |
|----------|------------------|--------|
| 改 shell 函式邏輯（setup.sh、build.sh 等） | Unit **必須**；視流程加 Integration | ShellCheck **必須** |
| 改 Dockerfile（新增 stage、調整 COPY） | System **必須**（Smoke type：image 起得來）；視 build flow 加 Integration | Hadolint **必須** |
| 改 entrypoint.sh / 容器啟動行為 | System **必須**（Smoke type）；視函式拆分加 Unit；視 multi-container 加 Integration | ShellCheck **必須** |
| 改 multi-container compose 行為 | Integration **必須**；視單容器加 System | compose lint 若有 |
| 改 CI workflow / reusable workflow | System **必須**（E2E type：PR 跑一次驗證觸發）；視協同加 Integration | actionlint 若有 |
| 純 lint 規則調整（`.hadolint.yaml` 等） | 通常 N/A | **必須**（跑全套確認無新 violation） |
| 文件 / 翻譯 | N/A | N/A（只看 doc-sync） |

### Rules

- **Lint（static）也算測試**：雖非「跑得起來」型，但同樣在 CI 強制；新檔 / 新規則要先讓 linter 失敗才修，不靠人工檢查
- **Smoke 是 type 不是 level**：base 在 Dockerfile `-test` stage build 時跑；docker_harness 無產品 image 故 N/A（原 `test/smoke/` 內容實為 Unit，已歸位 `.claude/test/bats/unit/`）
- **TEST.md 是 single source of truth**：各 level 的數量與位置記在 `doc/test/`（TEST.md 索引 + 每 level catalog：unit/integration/system/acceptance/smoke），每次新增 / 刪除 / 改名測試必須同步
- **驗證一律走 Docker**：所有 level 都透過 `just build test` / `just test`（base）或 `just -f .claude/test/justfile test`（docker_harness）在 Docker image 內執行，不接受本機 bats / shellcheck 通過作為驗證

## 12. Docker-only verification

**所有 lint 與 test 驗證只能透過 Docker 執行**，不要直接呼叫本機的
`bats`、`shellcheck`、`hadolint`、`kcov` 等工具。理由：
- 本機環境可能缺少 `bats-mock`、特定版本 bats-support / bats-assert，或
  shellcheck 版本與 CI 不同，會得到與 CI 不一致的結果
- CI 的 reusable workflow 也是透過同一組 Docker image 執行，走 Docker
  可以確保本地與 CI 行為一致

入口：
- `./build.sh test` — Dockerfile `test` stage（ShellCheck → Hadolint → Bats smoke）
- `just test` / `just test lint` — base 自身的 unit/integration 測試

## 13. Known gotchas

| 問題 | 原因 | 教訓 |
|------|------|------|
| `setup.sh` 直接執行時 IMAGE_NAME 偵測錯誤 | `_base_path` 預設用 `BASH_SOURCE` 目錄，不是 repo root | 涉及路徑的預設值要考慮所有呼叫方式 |
| Hadolint CI 太嚴導致全 fail | DL3008 等規則不適用 dev 環境 | 新增 lint 工具時先本地測試 |
| Docker COPY 不 follow symlinks | symlink 指向 .base/，Docker COPY 複製 symlink 本身 | 不要在需要 Docker COPY 的目錄中放 symlinks |
| `sed` apt mirror 在 `-euo pipefail` 下失敗 | glob 匹配不到檔案時 sed 回傳非零 | apt mirror sed 加 `\|\| true` |
| `.env.example` 刪除後 IMAGE_NAME 偵測失敗 | `detect_image_name` 只認 `docker_*` 和 `*_ws` | `.env.example` 保留作為 fallback |

## 14. Sandbox baseline (settings.json)

`.claude/settings.json` 的 sandbox section 是這個 repo 簡化 allow
list 的關鍵組合，新進來的人請理解這 4 個 key 做什麼：

```json
"sandbox": {
  "enabled": true,
  "autoAllowBashIfSandboxed": true,
  "excludedCommands": [
    "docker *", "make *",
    "./build.sh *", "./run.sh *", "./exec.sh *", "./stop.sh *",
    ".claude/scripts/*"
  ],
  "filesystem": { "allowWrite": ["/tmp"] }
}
```

| Key | 行為 |
|---|---|
| `enabled: true` | 對 Claude 跑的 Bash 加 sandbox（read-only fs + 限制 write/network），失敗會在錯誤訊息出現 "Operation not permitted" |
| `autoAllowBashIfSandboxed: true` | 若 Bash 命令在 sandbox 內跑得起來（沒撞 read-only / network 限制），**直接 allow 不問 user**，等於把所有 read-only Bash（`grep`、`awk`、`cat`、`ls`、`find` 等）自動放行 |
| `excludedCommands: ["docker *", ...]` | 列在這的 command **完全跳過 sandbox**（OS-level 不套 seatbelt/bubblewrap）。Anthropic 官方 [sandboxing 文件](https://code.claude.com/docs/en/sandboxing) 明確建議 docker 一定要列進來,因為 sandbox 會擋 `connect(AF_UNIX, /var/run/docker.sock)` syscall(refs issue #39)。`make *` 與 4 支 wrapper 一起列,因為它們內部也會 spawn docker。`.claude/scripts/*` 列進來解決 bwrap 對 `app/<repo>/.claude` symlink 的 overlay 衝突(下游 repo 的 `.claude` 是 symlink 到 workspace root,bwrap setup 撞到 `Can't create file at .../.claude: Is a directory` — refs #77 sub-3),信任邊界 == repo-owned scripts 已經過 PR review。pattern 是 prefix wildcard 同 `permissions.allow` |
| `filesystem.allowWrite: ["/tmp"]` | sandbox 預設禁寫入；這條讓 `/tmp` 可寫，配合「把長 body 寫成 `/tmp/<name>.md` 再給 `gh --body-file`」的 cheatsheet pattern |

**實際影響**：

- `permissions.allow` 不需要寫 `Bash(grep:*)` / `Bash(awk:*)` / `Bash(cat:*)` 等 read-only command — sandbox autoAllow 已 cover
- 只需要寫 **state-changing** commands：`Bash(git:*)`、`Bash(gh:*)`、`Bash(docker:*)`、`Bash(make:*)` 等（這些 sandbox 不 autoAllow，因為會改 state / network）
- `permissions.ask` 用來把高風險的 state-change（`Bash(rm:*)`、`Bash(git reset --hard:*)`、`Bash(docker push:*)` 等）**從 allow 拉出來**強制問 user，即使父規則 allow 也會被 ask 蓋過
- `excludedCommands` 的 docker / make / wrapper 不再需要 `dangerouslyDisableSandbox: true` per call — 解掉「驗證一律走 Docker」與 sandbox 的衝突(refs #39)

**什麼時候 sandbox 不夠**：parser fallback 不是 sandbox 問題（見下節「Bash command shape -- parser limits」），即使 sandbox autoAllow 也救不了 — 因為 fallback 發生在 sandbox 評估**之前**。

新 repo / 新 fork 想 port 這套 setup 時，先把 sandbox 那 4 個 key 貼進去（特別是 `excludedCommands` 一定要含 `docker *`,否則撞 #39 的 docker socket 問題）,再從這個 repo 的 `permissions.allow` 揀必要的 state-changing entries 過去就好；不要把 read-only entries 整批複製。

## 15. Bash command shape -- parser limits

Claude Code 的 bash AST parser 對某些 shell 構造會 fallback 到 prompt（即使
allowlist 涵蓋、`autoAllowBashIfSandboxed` 開啟也無效）。**主動避開以下
pattern**，改用替代寫法可以根除大量無謂的 user prompt：

| 觸發 prompt 的 pattern | parser 警告 | 替代寫法 |
|---|---|---|
| `cat <<EOF > /path` 寫檔 | `Unhandled node type: file_redirect` | **用 Write 工具**直接寫檔。非寫不可時用 `bash -c 'cat <<EOF > X ...'` 包起來 |
| `gh ... --body "$(cat path)"` / `--comment "$(cat path)"` / `--body-file - <<'EOF'`（heredoc 串 stdin） | `Unhandled node type: string` 或 `Contains zsh =cmd equals expansion` | **先 Write 落地成 `/tmp/<name>.md`，再 `gh ... --body-file /tmp/<name>.md`**（gh CLI 原生支援，所有 subcommand 都有；長 body 永遠寫成檔案，不要 inline、也不要串 stdin）。**`enforce_gh_body_file.sh` PreToolUse hook 會 BLOCK** 這兩個 pattern + 5 個額外 routing 違規(`gh issue/pr create` 必須 `--body-file`、`gh issue close --comment` 必須 two-step、`gh pr edit --body` inline、`gh issue|pr comment|pr review --body` inline > 80 字)。配對的 [[gh-artifact-format]] skill 講格式內容(title shape / body 5 sections / close 3 tiers / cross-ref keywords);refs #64 |
| `for x in $X; do ${x%:*}; done` 多 PR/repo for-loop | `Contains simple_expansion` | **抽永久 `.claude/scripts/<name>.sh`**，主程序只呼叫一行 |
| Monitor 內嵌 20+ 行 bash with `${var%:*}` 或 `<<<"$s"` | `Contains simple_expansion` / `Unhandled node type: string` | 同上，body 抽 script。PR CI 輪詢用 `.claude/scripts/wait-pr-ci.sh`；tag/branch CI 輪詢用 `.claude/scripts/wait-tag-ci.sh`（見 `.claude/skills/wait-pr-ci/SKILL.md`） |
| `cd path && git ...` | 內建 cd+git 安全警告（與上述 parser 無關） | **用 `git -C path <subcmd>`** 取代 |
| `(cd <repo>/worktree path && ./build.sh test)` 或 `bash -c "cd <dir> && ./build.sh ..."` | parser 只看 top-level token,subshell 是 `(`、`bash -c` 是 `bash`、都不命中 `excludedCommands: "./build.sh *"`,sandbox 套上去後 docker.sock 連不上 → `permission denied while trying to connect to the docker API at unix:///var/run/docker.sock` | **用 `./build.sh -C <dir> ...`**（同樣支援 `run.sh` / `exec.sh` / `stop.sh`,從 template v0.22.0 起,refs #53）。長形式 `--chdir`,行為對齊 `git -C` / `make -C`。Top-level token 留在 `./build.sh ...`,sandbox bypass 正常運作 |
| `gh pr merge N --repo X` 從非該 repo cwd | 內建 state-changing safety 提示（不可 bypass，與 parser、allowlist 都無關） | **接受 1-click 提示即可** — 這是合理的安全檢查，且 `docker` monorepo 裡沒有 `ycpss91255-docker/base` 的獨立 checkout（只是 git subtree），無法 cd 進去規避；`-R X` 短形式 / `(cd path && ...)` 子 shell 都不能繞 |
| `[[ a != b ]]` 在 Monitor 內 | Monitor eval wrapper escape `!` 成 `\!` | **用 `case` pattern**（見 `.claude/skills/wait-pr-ci/SKILL.md`） |
| `until ... $(cat <pidfile>) ...; do sleep N; done` 等 background task | `Contains command_substitution` | **用 `Bash` 的 `run_in_background`** — runtime 完成時自動通知，不用 poll。等 GitHub CI 用 `wait-pr-ci.sh` / `wait-tag-ci.sh`；等 local 長 process 用 `run_in_background` 起 task 然後做別的事 |
| `docker run ... bash -c '<長 inline 字串>'` 或 `docker compose ... bash -c '...'`（多行 shell logic 包在引號裡） | `Unhandled node type: string` | **抽成 script** — 用 Write 寫成 `/tmp/<name>.sh`，再 `docker run -v "$PWD":/source ... bash /source/<rel-path>/<name>.sh`；或抽 permanent `.claude/scripts/<name>.sh` 接 atomic flags（如 `run-bats-in-compose.sh --suite all --grep '^not ok'`），Claude parser 只看到 atomic args 不 hit string node。長 quoted body 永遠抽成檔案，不要 inline |

對應的 hook 補強：

- `.claude/hooks/remind_no_heredoc_redirect.sh` — heredoc-to-file 寫法 (non-blocking remind)
- `.claude/hooks/enforce_gh_body_file.sh` — `gh` body-file 規律 BLOCKING (rules 1-8 in `.claude/skills/gh-artifact-format/SKILL.md`, refs #64)

其他 pattern（複雜 for-loop / Monitor body）沒有簡單 heuristic，靠這個
section 的規則 + `[[skillification-candidates]]` skill 在任務結束時主動列
skill 化候選收斂。

### Hook 解析 command 的共同規則（refs #255 / #276 / #283）

寫 hook 判斷一條 bash command 時，**先確定「跑的是哪個 command」，再判斷
它包含什麼**——四次同型 bug 都是把資料當語法：

- heredoc body 是資料不是 command（先剝掉）；backslash 續行是同一個
  command 的一部分（先折成一行）——換行本身仍然是 command 邊界。
- 以 shell 分隔符（`&&` `||` `|` `;` 換行）切段後，只認「命令字本身」就是
  目標程式的那一段；引號參數裡提到的 `git` / `gh` 是別人的字串。
- 放寬的只有「這條是不是那個 command」的判斷，規則本身（`--body-file`
  routing、artifact 只能英文）一律不放寬。

## 16. Per-project memory (repo-portable via symlink)

Claude Code 的 per-project memory 預設存在
`~/.claude/projects/<encoded-workspace-path>/memory/`,其中
`<encoded-workspace-path>` 是把 workspace 絕對路徑的 `/` 換成 `-`
（例如 `/home/yunchien/workspace/docker` →
`-home-yunchien-workspace-docker`）。這個路徑被 workspace 絕對位置
鎖死,**換機器或改 workspace 路徑就會失聯**。

為了讓 memory 跟 repo 走 + 進 git history,實際 memory 檔案存在
`<workspace>/.claude/memory/`(git-tracked),Claude Code 預期的位置
則用 symlink 連回來：

```
<workspace>/.claude/memory/                       (git-tracked source of truth)
├── MEMORY.md                                     (index, <=150 chars/line)
├── feedback_*.md                                 (workflow / convention rules)
└── project_*.md                                  (project context)

~/.claude/projects/-home-yunchien-workspace-docker/memory  ->  symlink -> <workspace>/.claude/memory
```

### Fresh-clone / new-machine setup

跑一次：

```bash
bash .claude/scripts/setup-memory-link.sh
```

idempotent — 偵測現有 symlink target,已正確就 skip；偵測舊
non-symlink 資料夾且內容跟 repo 一致就 rm + symlink；偵測新內容
（這台機器才有的 entry）就 refuse 並要求先 merge 進 repo,除非
`--force`(會先備份成 `.backup-<timestamp>`)。

`--dry-run` 看預期動作。`--workspace <path>` / `--home <path>` 給
測試用 override。

### Memory file format (unchanged)

仍依 Claude Code 標準格式：

- frontmatter `name` (kebab-case slug) + `description` + `metadata.type`
  (`user` / `feedback` / `project` / `reference`)
- 主檔名跟 `name` 對齊（如 `feedback_no_emoji.md`）
- `MEMORY.md` 是 index — 一行一個 entry,`- [Title](file.md) -- hook`
- 用 `[[name]]` 連 related memories

詳細寫法見 auto-memory section（system prompt 開頭）。
