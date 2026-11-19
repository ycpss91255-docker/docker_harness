#!/usr/bin/env bash
# deny_ai_attribution_commit.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# Denies a `git ... commit` or `gh pr merge` whose message carries an AI
# attribution marker, before it runs (refs base#1988). Scans the command text,
# any -F / --file / --body-file file, and for a `gh pr merge` without --body /
# --body-file the PR body from `gh pr view`. Which command runs is read per
# segment (lib/gh-command.sh), so `git log --grep '... commit ...'` is not one.
# Matcher shared with the commit-msg hook (lib/attribution_marker.sh).
# Catches honest mistakes, not deliberate evasion; the CI check (base#1989) is
# the backstop. Every internal error fails open (silent exit 0).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../scripts/lib/attribution_marker.sh
source "${HOOK_DIR}/../scripts/lib/attribution_marker.sh" 2>/dev/null || exit 0
# shellcheck source=SCRIPTDIR/../scripts/lib/gh-command.sh
source "${HOOK_DIR}/../scripts/lib/gh-command.sh" 2>/dev/null || exit 0

# segments <cmd> -- one command per line: heredoc bodies dropped, line
# continuations folded, split on && || | ; and newline.
segments() {
  local c
  c="$(fold_continuations "$(strip_heredocs "$1")")"
  c="${c//&&/$'\n'}"; c="${c//||/$'\n'}"; c="${c//|/$'\n'}"
  printf '%s\n' "${c//;/$'\n'}"
}

# verb <seg> -- "commit" for `git [globals] commit`, "merge" for
# `gh pr merge`, nothing otherwise. Skips leading VAR=val env prefixes.
verb() {
  local -a w
  read -ra w <<< "$1"
  local i=0 n=${#w[@]}
  while (( i < n )) && [[ "${w[i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do i=$((i + 1)); done
  if [[ "${w[i]:-}" == "git" ]]; then
    for ((i = i + 1; i < n; i++)); do
      [[ "${w[i]}" == -* ]] || break
      [[ "${w[i]}" =~ ^(-C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix)$ ]] && i=$((i + 1))
    done
    [[ "${w[i]:-}" == "commit" ]] && echo commit
  elif [[ "${w[i]:-} ${w[i + 1]:-} ${w[i + 2]:-}" == "gh pr merge" ]]; then
    echo merge
  fi
}

# message_files <seg> -- each -F / --file / --body-file path, quotes removed.
message_files() {
  local -a w; local i f
  read -ra w <<< "$1"
  for ((i = 0; i < ${#w[@]}; i++)); do
    case "${w[i]}" in -F | --file | --body-file) f="${w[i + 1]:-}" ;;
      --file=* | --body-file=*) f="${w[i]#*=}" ;; *) continue ;; esac
    f="${f%[\"\']}"; f="${f#[\"\']}"
    [[ -n "${f}" && "${f}" != "-" ]] && printf '%s\n' "${f}"
  done
}

# pr_body <seg> <cwd> -- the stored body of the PR a `gh pr merge` targets,
# looked up from <cwd> with the segment's --repo; nothing when the command
# supplies its own body or the lookup fails.
pr_body() {
  [[ " $1 " =~ [[:space:]](-b|--body|-F|--body-file)([[:space:]]|=) ]] && return 0
  local -a w
  read -ra w <<< "${1#*gh pr merge}"
  local n="${w[0]:-}" repo body
  [[ "${n}" == -* ]] && n=""
  repo="$(gh_repo_flag "$1")"
  body="$(cd "${2:-.}" && timeout 10 gh pr view ${n:+"${n}"} ${repo:+--repo "${repo}"} \
    --json body -q .body 2>/dev/null)" || return 0
  printf '%s\n' "${body}"
}

main() {
  local input cmd cwd seg v f match extra="" gated=0
  input="$(cat)"
  cmd="$(jq -r '.tool_input.command // empty' <<< "${input}" 2>/dev/null)" || return 0
  [[ "${cmd}" == *commit* || "${cmd}" == *merge* ]] || return 0
  cwd="$(jq -r '.cwd // empty' <<< "${input}" 2>/dev/null)" || cwd=""
  while IFS= read -r seg; do
    v="$(verb "${seg}")"
    [[ -n "${v}" ]] || continue
    gated=1
    while IFS= read -r f; do
      [[ "${f}" != /* && -n "${cwd}" ]] && f="${cwd}/${f}"
      [[ -f "${f}" ]] && extra+="$(cat -- "${f}" 2>/dev/null)"$'\n'
    done < <(message_files "${seg}")
    [[ "${v}" == "merge" ]] && extra+="$(pr_body "${seg}" "${cwd}")"$'\n'
  done < <(segments "${cmd}")
  (( gated )) || return 0
  match="$(printf '%s\n%s' "${cmd}" "${extra}" | attribution_marker_find)" || return 0
  local msg="AI attribution gate (base#1988): the commit message carries an AI attribution marker: '${match}'. Remove it and commit again."
  jq -n --arg m "${msg}" '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PreToolUse",
    permissionDecision: "deny", permissionDecisionReason: $m}}'
  return 0
}

main "$@"
