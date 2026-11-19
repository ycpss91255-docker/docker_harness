#!/usr/bin/env bash
# deny_ai_attribution_commit.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# Denies a `git ... commit` whose command text or -F / --file message file
# carries an AI attribution marker, or a `gh pr merge` whose PR body does,
# before it runs (refs
# base#1988). The matcher is shared with the commit-msg hook
# (.claude/scripts/lib/attribution_marker.sh).
#
# Catches honest mistakes, not deliberate evasion; the CI check (base#1989) is
# the backstop. Every internal error fails open (silent exit 0).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="${HOOK_DIR}/../scripts/lib/attribution_marker.sh"
[[ -f "${lib}" ]] || exit 0
# shellcheck source=SCRIPTDIR/../scripts/lib/attribution_marker.sh
source "${lib}"

# message_files <cmd> -- print each path passed with -F / --file, one per line,
# with one layer of surrounding quotes removed.
message_files() {
  local -a words
  read -ra words <<< "$1"
  local i f
  for ((i = 0; i < ${#words[@]}; i++)); do
    case "${words[i]}" in
      -F | --file) f="${words[i + 1]:-}" ;;
      --file=*) f="${words[i]#--file=}" ;;
      *) continue ;;
    esac
    f="${f%\"}"; f="${f#\"}"; f="${f%\'}"; f="${f#\'}"
    printf '%s\n' "${f}"
  done
}

# pr_body <cmd> -- for `gh pr merge [<n>]`, print that PR's body via gh.
pr_body() {
  local -a words
  read -ra words <<< "${1#*gh pr merge}"
  local n="${words[0]:-}"
  [[ "${n}" == -* ]] && n=""
  timeout 10 gh pr view ${n:+"${n}"} --json body -q .body 2>/dev/null
}

main() {
  local input cmd cwd match f
  input="$(cat)"
  cmd="$(jq -r '.tool_input.command // empty' <<< "${input}" 2>/dev/null)" || return 0
  [[ "${cmd}" =~ git.*commit || "${cmd}" == *"gh pr merge"* ]] || return 0
  cwd="$(jq -r '.cwd // empty' <<< "${input}" 2>/dev/null)" || cwd=""
  match="$(
    {
      printf '%s\n' "${cmd}"
      while IFS= read -r f; do
        [[ -n "${f}" && "${f}" != /* && -n "${cwd}" ]] && f="${cwd}/${f}"
        [[ -f "${f}" ]] && cat -- "${f}" 2>/dev/null
      done < <(message_files "${cmd}") || true
      if [[ "${cmd}" == *"gh pr merge"* ]]; then pr_body "${cmd}" || true; fi
    } | attribution_marker_find
  )" || return 0
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
