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
# Trigger pattern: `gh pr create` appears in any segment of the command
# (including chained `&&`).

set -uo pipefail

main() {
  local input cmd msg
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"

  [[ -z "${cmd}" ]] && return 0

  [[ "${cmd}" =~ gh[[:space:]]+pr[[:space:]]+create ]] || return 0

  msg="PR open reminder: don't sleep-poll. After opening, run the auto-merge-on-green skill (.claude/skills/auto-merge-on-green/SKILL.md) -- arm GitHub-native auto-merge (--auto --squash --delete-branch) and wrap .claude/scripts/auto-merge-on-green.sh in a single Monitor: on green CI GitHub merges server-side, BEHIND triggers an automatic update-branch, and a CI failure is only reported while auto stays armed (a fix-push lands it automatically). Use wait-pr-ci only for pure monitoring (no merge)."

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
