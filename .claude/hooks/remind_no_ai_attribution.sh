#!/usr/bin/env bash
# remind_no_ai_attribution.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. When the command embeds AI-attribution
# markers in a git/gh argument (commit -m, gh pr create --body, etc.), emit
# a JSON systemMessage. Non-blocking — exit 0.
#
# Why: CLAUDE.md「不加 AI 歸屬標記」(no AI-attribution markers) expressly
# forbids such messages in a commit message / PR body / code comment. The
# on-disk case is caught by check_no_ai_attribution.sh (PostToolUse
# Edit/Write); the case where an inline string is passed directly on the
# command line is caught by this hook
# (e.g. `git commit -m "feat: x\n\nCo-Authored-By: Claude ..."`).
#
# Trigger: command contains `git commit`/`gh pr create`/`gh pr edit`/
# `gh pr comment`/`gh issue create`/`gh issue edit`/`gh issue comment`,
# and an AI-attribution pattern is detected in the command string.

set -uo pipefail

main() {
  local input cmd msg
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"

  [[ -z "${cmd}" ]] && return 0

  case "${cmd}" in
    *"git commit"*|*"gh pr create"*|*"gh pr edit"*|*"gh pr comment"*) ;;
    *"gh issue create"*|*"gh issue edit"*|*"gh issue comment"*) ;;
    *) return 0 ;;
  esac

  if ! printf '%s' "${cmd}" | grep -qiE 'Generated with (\[)?Claude Code|Co-Authored-By:[[:space:]]*Claude'; then
    return 0
  fi

  msg="AI-attribution marker in command (CLAUDE.md「不加 AI 歸屬標記」/ no AI-attribution markers: never add Generated with Claude Code, Co-Authored-By: Claude, etc. Useless to reviewers, just visual noise). Remove these lines from the message before you commit / open the PR."

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
