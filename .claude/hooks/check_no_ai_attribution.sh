#!/usr/bin/env bash
# check_no_ai_attribution.sh — Claude Code PostToolUse hook
#
# Fires on Edit / Write / MultiEdit. Scans the touched file for AI-attribution
# markers (e.g. "Generated with Claude Code", "Co-Authored-By: Claude ...").
# Non-blocking — exit 0; emits a JSON systemMessage on hits.
#
# Why: CLAUDE.md「不加 AI 歸屬標記」(no AI-attribution markers) explicitly
# forbids such messages in commit message / PR body / code comment — they
# are useless to reviewers, just visual noise. When Claude writes a commit
# message temp file (-F) or a PR body file (--body-file), this hook catches
# the problem the moment the file lands. The case of passing the string
# directly on the command line is handled by remind_no_ai_attribution.sh
# (PreToolUse Bash).
#
# Patterns (case-insensitive):
#   - Generated with [Claude Code]  /  Generated with Claude Code
#   - Co-Authored-By: Claude
#   - "robot-emoji Generated with" and similar common boilerplate (the emoji is caught by check_no_emoji)

set -uo pipefail

main() {
  local input file_path hits msg
  input="$(cat)"
  file_path="$(printf '%s' "${input}" | jq -r '
    .tool_input.file_path
    // .tool_response.filePath
    // empty
  ' 2>/dev/null)"

  [[ -z "${file_path}" || ! -f "${file_path}" ]] && return 0

  case "${file_path}" in
    */.git/*|*/node_modules/*|*/coverage/*|*/.cache/*) return 0 ;;
    */check_no_ai_attribution.sh|*/remind_no_ai_attribution.sh) return 0 ;;
    # Meta-rule docs that legitimately quote the forbidden patterns to forbid them.
    */CLAUDE.md|*/.claude/commands/*.md|*/.claude/skills/*/SKILL.md) return 0 ;;
    */.claude/instincts.yaml) return 0 ;;
    # Project doc conventions that catalog/describe rule violations.
    */doc/test/TEST.md|*/doc/changelog/CHANGELOG.md) return 0 ;;
    # Hook-test fixtures must contain the forbidden patterns to assert detection.
    */.claude/hooks/test/*) return 0 ;;
  esac

  if file --mime "${file_path}" 2>/dev/null | grep -qE 'charset=binary'; then
    return 0
  fi

  hits="$(grep -niE 'Generated with (\[)?Claude Code|Co-Authored-By:[[:space:]]*Claude' \
    "${file_path}" 2>/dev/null \
    | head -5 \
    | awk -F: '{
        line=$1; $1=""; sub(/^ /, "");
        snippet=$0; if (length(snippet) > 80) snippet=substr(snippet, 1, 80);
        printf "  line %s: %s\n", line, snippet
      }')"

  [[ -z "${hits}" ]] && return 0

  msg="$(printf 'AI attribution marker in %s (CLAUDE.md「不加 AI 歸屬標記」(no AI-attribution markers): never add Generated with Claude Code, Co-Authored-By: Claude, etc. to PR body / commit message / code comment):\n%s' \
    "${file_path}" "${hits}")"

  jq -n --arg m "${msg}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $m
    }
  }'

  return 0
}

main "$@"
