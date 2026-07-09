#!/usr/bin/env bash
# check_no_coverage_excl.sh — Claude Code PostToolUse hook
#
# Fires on Edit / Write / MultiEdit. Scans the touched file for coverage
# exclusion comments (LCOV_EXCL_LINE / LCOV_EXCL_START / LCOV_EXCL_STOP /
# kcov-excl) and emits a JSON systemMessage on hits. Non-blocking — always
# exit 0.
#
# Why: CLAUDE.md「風格規範」(style guidelines) forbids hiding uncovered
# code behind comments. Show the real coverage; fill the uncovered parts
# with tests instead of masking them with comments.
#
# Pattern: extended regex matches LCOV_EXCL_(LINE|START|STOP) and kcov-excl
# regardless of comment marker (#, //, --, etc.). Skip the hook itself
# (it documents the pattern in comments).

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
    */check_no_coverage_excl.sh) return 0 ;;
    # Test specs / fixtures must contain the forbidden patterns to assert detection.
    */.claude/test/bats/*) return 0 ;;
    *.md) return 0 ;;
  esac

  if file --mime "${file_path}" 2>/dev/null | grep -qE 'charset=binary'; then
    return 0
  fi

  hits="$(grep -nE 'LCOV_EXCL_(LINE|START|STOP)|kcov-excl' "${file_path}" 2>/dev/null \
    | head -5 \
    | awk -F: '{
        line=$1; $1=""; sub(/^ /, "");
        snippet=$0; if (length(snippet) > 80) snippet=substr(snippet, 1, 80);
        printf "  line %s: %s\n", line, snippet
      }')"

  [[ -z "${hits}" ]] && return 0

  msg="$(printf 'coverage-exclusion comment not allowed in %s (CLAUDE.md「風格規範」(style guidelines): fill uncovered code with tests, do not mask it with comments):\n%s' \
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
