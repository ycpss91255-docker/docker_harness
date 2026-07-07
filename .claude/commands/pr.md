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
   - Do NOT add AI attribution lines (e.g. `Co-Authored-By: Claude ...`, `Generated with Claude Code`); CLAUDE.md「不加 AI 歸屬標記」(no AI-attribution markers) explicitly forbids this.

5. **Push branch, create PR**:
   ```
   git push -u origin <branch-name>
   # PR body must go through --body-file (enforce_gh_body_file.sh hook BLOCKs inline --body)
   # Write it to /tmp/pr-<slug>-body.md first, then:
   gh pr create --title "<type>: <title>" --body-file /tmp/pr-<slug>-body.md
   ```
   Arming GitHub auto-merge + watching it land is handled by step 6's `auto-merge-on-green` skill (it runs `gh pr merge --auto --squash --delete-branch`). All active repos already have `allow_auto_merge` enabled. `.github` is the exception: a doc-only PR + paths filter leaves the status check pending forever, so auto-merge stalls — for that repo use a manual `gh pr merge` instead.

   For the PR body shape, see `.claude/skills/gh-artifact-format/SKILL.md` (the issue body has the same 5 sections, but a PR adds a `## Test plan` checklist). The skill also covers close-comment 3 tiers / non-closing comment 3 categories / cross-ref keywords (`Closes` / `Fixes` / `refs` / `supersedes` / `closes part of`).

6. **Land the PR via `auto-merge-on-green`** (the canonical flow for landing a single PR):
   - Use the `auto-merge-on-green` skill (`.claude/skills/auto-merge-on-green/SKILL.md`): a single Monitor wraps `.claude/scripts/auto-merge-on-green.sh --repo <O>/<R> --pr <N>` — it arms GitHub auto-merge, polls `mergeStateStatus`, runs `gh pr update-branch` automatically on `BEHIND` (replacing the old manual `git pull --rebase` + force-push), and on CI failure reports back while staying armed (a fix-push lands automatically). The `remind_ci_auto_merge` hook reminds you after `gh pr create`.
   - Only for pure monitoring (no merge — e.g. the base repo needs a follow-up tag + downstream fanout, or you are waiting on some other action that depends on merged state) use the `wait-pr-ci` skill to wait for `ALL_DONE`.
   - dependabot PR stuck at BEHIND: leave a `@dependabot rebase` comment. `.github` doc-only PR: auto-merge stalls, so merge manually with `gh pr merge`.

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
