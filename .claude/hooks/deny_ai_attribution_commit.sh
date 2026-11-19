#!/usr/bin/env bash
# deny_ai_attribution_commit.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# Denies a `git ... commit` whose command text carries an AI attribution
# marker, before the commit runs (refs base#1988). The matcher is shared with
# the commit-msg hook (.claude/scripts/lib/attribution_marker.sh).
#
# Catches honest mistakes, not deliberate evasion; the CI check (base#1989) is
# the backstop. Every internal error fails open (silent exit 0).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="${HOOK_DIR}/../scripts/lib/attribution_marker.sh"
[[ -f "${lib}" ]] || exit 0
# shellcheck source=SCRIPTDIR/../scripts/lib/attribution_marker.sh
source "${lib}"

main() {
  local cmd match
  cmd="$(jq -r '.tool_input.command // empty' 2>/dev/null)" || return 0
  [[ "${cmd}" =~ git.*commit ]] || return 0
  match="$(printf '%s\n' "${cmd}" | attribution_marker_find)" || return 0
  local msg="AI attribution gate (base#1988): the commit message carries an AI attribution marker: '${match}'. Remove it and commit again."
  jq -n --arg m "${msg}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $m
    }
  }'
  return 0
}

main "$@"
