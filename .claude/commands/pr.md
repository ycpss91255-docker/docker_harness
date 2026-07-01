Create a PR for a bug fix, new feature, or refactoring. TRIGGER when: user asks to fix a bug, add a feature, refactor code, modify scripts (`*.sh`), Dockerfile, compose.yaml, CI workflows (`.github/workflows/*`), `.claude/**`, or any other source under `ycpss91255-docker/*`. Apply this workflow proactively without waiting for the user to type `/pr` — natural-language requests like 「處理 xxx」「修 xxx」「加 --foo flag」「重構 yyy」 all count.

IMPORTANT: All code changes (bug fix, new feature, refactoring, file moves, path changes, Dockerfile changes) MUST go through this PR workflow. Only pure documentation updates (README text, CLAUDE.md) can be pushed directly to main.

Follow this workflow:

1. **Create branch** from main:
   - Bug fix: `fix/<short-description>`
   - New feature: `feat/<short-description>`
   - Refactoring: `refactor/<short-description>`

2. **Make changes** (code, tests, docs)
   - Bug fix: MUST include a regression test
   - New feature: include tests if applicable
   - Refactoring: verify existing tests still pass
   - Update README if the change is user-facing

3. **Verify locally**:
   - Run `shellcheck -S warning *.sh` on changed .sh files
   - Run `./build.sh test` if Dockerfile or smoke tests changed
   - Run `just -f justfile.ci test` if working in the base repo

4. **Commit** with conventional message:
   - Bug fix: `fix: <description>`
   - New feature: `feat: <description>`
   - Refactoring: `refactor: <description>`
   - Docs only: `docs: <description>`
   - Do NOT add AI attribution lines (e.g. `Co-Authored-By: Claude ...`, `Generated with Claude Code`); CLAUDE.md「不加 AI 歸屬標記」明文禁止。

5. **Push branch, create PR**:
   ```
   git push -u origin <branch-name>
   # PR body 必須走 --body-file (enforce_gh_body_file.sh hook BLOCK inline --body)
   # 先 Write 寫到 /tmp/pr-<slug>-body.md,再:
   gh pr create --title "<type>: <title>" --body-file /tmp/pr-<slug>-body.md
   ```
   arming GitHub auto-merge + 監看落地交給 step 6 的 `auto-merge-on-green` skill(它跑 `gh pr merge --auto --squash --delete-branch`)。所有 active repo 都已開啟 `allow_auto_merge`。`.github` 例外:doc-only PR + paths filter 會讓 status check 永遠 pending,auto-merge 卡死 — 該 repo 改走手動 `gh pr merge`。

   PR body shape 規範參見 `.claude/skills/gh-artifact-format/SKILL.md`(issue body 同 5 sections,但 PR 多一個 `## Test plan` checklist)。Skill 也涵蓋 close-comment 3 tiers / non-closing comment 3 categories / cross-ref keywords (`Closes` / `Fixes` / `refs` / `supersedes` / `closes part of`)。

6. **Land the PR via `auto-merge-on-green`**(canonical 落地單一 PR 流程):
   - 用 `auto-merge-on-green` skill (`.claude/skills/auto-merge-on-green/SKILL.md`):一個 Monitor 包 `.claude/scripts/auto-merge-on-green.sh --repo <O>/<R> --pr <N>` — 它 arm GitHub auto-merge、輪詢 `mergeStateStatus`、`BEHIND` 自動 `gh pr update-branch`(取代以前手動 `git pull --rebase` + force-push)、CI 失敗回報且保留 armed(fix-push 自動落地)。`remind_ci_auto_merge` hook 會在 `gh pr create` 後提醒。
   - 純監看(不 merge,例如 base repo 要接 tag + 下游 fanout,或等其他依賴 merged state 的動作)才用 `wait-pr-ci` skill 等 `ALL_DONE`。
   - dependabot PR 卡 BEHIND:留 `@dependabot rebase` comment。`.github` doc-only PR:auto-merge 卡死,手動 `gh pr merge`。

7. **If this PR was on the `base` repo**: after merge + tag, the
   13 downstream repos need the new `.base/` subtree version pulled.
   **Scope: workspace cwd only** — the fanout below assumes
   `${CLAUDE_PROJECT_DIR}` is the workspace dir that contains all 13
   sub-repos. If the current session was started inside a single repo
   (per-repo cwd), skip step 7 entirely and instead run
   `/batch-base-upgrade <vX.Y.Z>` from a workspace session, which
   handles the same fan-out via a permanent script and avoids `cd`
   parser warnings:
   ```
   .claude/scripts/batch-base-upgrade.sh vX.Y.Z --why "..." --issue <num>
   ```
   Manual fan-out (kept for reference; prefer the batch script):
   ```
   for repo in env/ros_distro env/ros2_distro agent/ai_agent agent/claude_code agent/codex_cli agent/gemini_cli app/realsense_ros2 app/realsense_ros1 app/sick_humble app/sick_noetic app/urg_node_noetic app/ros1_bridge app/urg_node_humble; do
     git -C "${CLAUDE_PROJECT_DIR}/$repo" pull
     (cd "${CLAUDE_PROJECT_DIR}/$repo" && ./.base/upgrade.sh && git push)
   done
   ```
   For non-base PRs (fix / feat / refactor on a single repo), step 7
   is **N/A** — your work ends at step 6.

Context from user: $ARGUMENTS

Now execute this workflow for the described change.
