#!/usr/bin/env bash
# auto_clean_worktree_leak.sh -- Claude Code PreToolUse hook (matcher: Bash, refs #167).
#
# Fires before a Bash command runs. When the command is a main-checkout
# sync operation that would fail if working-tree M files conflict with
# the merge, scan for unwhitelisted M files and:
#   1. Append a "cleaned" event to ~/.claude/log/worktree-leak-events.jsonl
#      (forensic record before mutation).
#   2. Run `git checkout HEAD -- <leaked-files>` to restore tracked
#      content (the leak is by definition content that does not belong
#      in the main checkout's tracked state).
#   3. Exit 0 so the original command runs against a clean tree.
#
# Triggers on (cmd substring match):
#   - `git pull *`
#   - `git checkout origin/main` (and similar)
#   - `git merge origin/*`
#
# Whitelist (same as forensic_worktree_leak.sh): never clean these.
#   - .claude/instincts.yaml
#   - .claude/memory/**
#
# Non-blocking: any error path silently exits 0 so the user's command
# still runs (or fails with its own clean error).

set -uo pipefail

WHITELIST_EXACT=(
  ".claude/instincts.yaml"
)
WHITELIST_PREFIX=(
  ".claude/memory/"
)

is_whitelisted() {
  local path="$1" p
  for p in "${WHITELIST_EXACT[@]}"; do
    [[ "${path}" == "${p}" ]] && return 0
  done
  for p in "${WHITELIST_PREFIX[@]}"; do
    [[ "${path}" == "${p}"* ]] && return 0
  done
  return 1
}

main() {
  local input cmd cwd session_id
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  cwd="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
  session_id="$(printf '%s' "${input}" | jq -r '.session_id // empty' 2>/dev/null)"
  [[ -z "${cmd}" ]] && return 0

  # Trigger only on main-checkout sync commands.
  local trigger=0
  if [[ "${cmd}" =~ git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*pull([[:space:]]|$) ]]; then
    trigger=1
  elif [[ "${cmd}" =~ git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*checkout[[:space:]]+origin/ ]]; then
    trigger=1
  elif [[ "${cmd}" =~ git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*merge[[:space:]]+origin/ ]]; then
    trigger=1
  fi
  (( trigger )) || return 0

  # Resolve main checkout. Prefer CLAUDE_PROJECT_DIR, fall back to cwd.
  local main_dir="${CLAUDE_PROJECT_DIR:-${cwd}}"
  [[ -z "${main_dir}" || ! -d "${main_dir}/.git" ]] && return 0

  # Detect unwhitelisted M files.
  local porcelain
  porcelain="$(git -C "${main_dir}" status --porcelain 2>/dev/null || true)"
  [[ -z "${porcelain}" ]] && return 0

  local leaked=()
  local line path
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    [[ "${line:0:2}" =~ [MR][MD\ ]|[\ ][M] ]] || continue
    path="${line:3}"
    path="${path%% *}"
    is_whitelisted "${path}" && continue
    leaked+=("${path}")
  done <<< "${porcelain}"
  (( ${#leaked[@]} == 0 )) && return 0

  # Build JSONL event before mutation (so forensic record survives).
  local log_dir="${HOME}/.claude/log"
  mkdir -p "${log_dir}" 2>/dev/null || true
  local log_file="${log_dir}/worktree-leak-events.jsonl"
  local ts main_head
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  main_head="$(git -C "${main_dir}" rev-parse HEAD 2>/dev/null || echo "?")"

  local files_json
  files_json="$(
    for path in "${leaked[@]}"; do
      local diff_head
      diff_head="$(git -C "${main_dir}" diff HEAD -- "${path}" 2>/dev/null | head -30)"
      jq -cn --arg p "${path}" --arg d "${diff_head}" '{path:$p, diff_head:$d}'
    done | jq -cs '.'
  )"

  ( printf '{"ts":"%s","session_id":"%s","event":"cleaned","main_head":"%s","leaked_files":%s,"trigger_cmd":%s}\n' \
      "${ts}" "${session_id}" "${main_head}" "${files_json}" "$(jq -Rn --arg c "${cmd}" '$c')" \
      >> "${log_file}" ) 2>/dev/null || true

  # Restore each leaked path to its committed content.
  local path
  for path in "${leaked[@]}"; do
    git -C "${main_dir}" checkout HEAD -- "${path}" 2>/dev/null || true
  done
}

main
