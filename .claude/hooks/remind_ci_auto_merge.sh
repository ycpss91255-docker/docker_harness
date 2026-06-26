#!/usr/bin/env bash
# remind_ci_auto_merge.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. When the command opens a GitHub PR
# (`gh pr create ...`), emit a JSON systemMessage telling the agent to run the
# auto-merge-on-green skill (arm GitHub-native auto-merge + Monitor-wrap
# auto-merge-on-green.sh) instead of sleep-polling. Non-blocking (always 0).
#
# The hook only DETECTS + INSTRUCTS; it cannot run a Monitor or merge itself
# (Claude Code hooks are synchronous, short-lived). The agent + skill execute;
# GitHub merges server-side. Refs #211 (renamed from remind_pr_wait_ci.sh).
#
# Scope note: this hook owns ONLY the `gh pr create` trigger. The `git push`
# re-push path is owned by remind_monitor_on_git_push.sh (which carries the
# -u / main / tag exclusions), and `gh workflow run` / `gh run rerun` by
# remind_monitor_on_ci_trigger.sh. Keeping them separate avoids double-firing.
#
# Trigger pattern: `gh pr create` 出現在 command 任一段（含 chained `&&`）。

set -uo pipefail

main() {
  local input cmd msg
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"

  [[ -z "${cmd}" ]] && return 0

  [[ "${cmd}" =~ gh[[:space:]]+pr[[:space:]]+create ]] || return 0

  msg="PR open 提醒：別 sleep 輪詢。開完跑 auto-merge-on-green skill（.claude/skills/auto-merge-on-green/SKILL.md）—— 掛 GitHub 原生 auto-merge（--auto --squash --delete-branch）並用一個 Monitor 包 .claude/scripts/auto-merge-on-green.sh：CI 綠由 GitHub 伺服器端自動合,BEHIND 自動 update-branch,CI 失敗只回報且 auto 保留掛著(fix-push 會自動落地)。純監看(不 merge)才用 wait-pr-ci。"

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
