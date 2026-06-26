#!/usr/bin/env bash
# remind_monitor_on_git_push.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. When the command re-pushes / force-pushes
# an existing PR branch (CI re-runs on the new head, but there is no
# `gh pr create` event to re-trigger remind_ci_auto_merge), emit a JSON
# systemMessage reminding to drive the same PR to land via the
# auto-merge-on-green skill on the new head. Non-blocking (always exit 0).
#
# This completes the CI-watch coverage umbrella (#157, #211):
#   - gh pr create                 -> remind_ci_auto_merge.sh
#   - gh run rerun / workflow run  -> remind_monitor_on_ci_trigger.sh
#   - git push (re-push)           -> THIS hook
#
# FIRE when the command is a `git push` (including `git -C <dir> push`,
# `--force`, `--force-with-lease`, `git push origin <branch>`) that:
#   - does NOT carry `-u` / `--set-upstream` (initial push; the
#     subsequent `gh pr create` reminder covers that path), AND
#   - does NOT target `main` (doc-only direct push, no PR CI to watch), AND
#   - is NOT a version-tag push (`git push origin vX.Y.Z` — that surface
#     is owned by enforce_semver_tag_via_script.sh, not a PR branch).
#
# Everything else (non-push git, non-git) is silent.

set -uo pipefail

main() {
  local input cmd msg
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [[ -z "${cmd}" ]] && return 0

  # Must be a `git push` (allow a leading `git -C <dir>`).
  [[ "${cmd}" =~ git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?push([[:space:]]|$) ]] || return 0

  # Initial push: the following `gh pr create` reminder covers it.
  [[ "${cmd}" =~ (^|[[:space:]])(-u|--set-upstream)([[:space:]]|$) ]] && return 0

  # Push targeting main: doc-only direct push, no PR CI to watch.
  [[ "${cmd}" =~ (^|[[:space:]:])main([[:space:]]|$) ]] && return 0

  # Version-tag push: owned by enforce_semver_tag_via_script.sh.
  [[ "${cmd}" =~ (^|[[:space:]:/])v[0-9]+\.[0-9]+\.[0-9]+ ]] && return 0

  # Bulk tag push (`git push --tags`): not a PR branch.
  [[ "${cmd}" =~ (^|[[:space:]])--tags([[:space:]]|$) ]] && return 0

  msg="git push 提醒：對既有 branch 的 re-push / force-push，CI 會在新 head 重跑。若該分支已有 PR,用 auto-merge-on-green skill（.claude/skills/auto-merge-on-green/SKILL.md,arm 為 idempotent)確認落地;armed 的 PR 綠後 GitHub 會自動合,BEHIND 自動 update-branch。純監看(不 merge)才用 wait-pr-ci。別 sleep 輪詢。(初次 -u push 由 gh pr create 提醒接手；推 main / tag 不在此列)"

  jq -n --arg m "${msg}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $m
    }
  }'

  return 0
}

main "$@"
