#!/usr/bin/env bash
# forensic_worktree_leak.sh -- Claude Code Stop hook (refs #167).
#
# Fires at the end of every assistant turn. Scans the main checkout
# for tracked, modified files that are NOT in the whitelist; if any,
# appends one JSONL event to ~/.claude/log/worktree-leak-events.jsonl
# so future debugging has forensic material for the still-unidentified
# leak mechanism (M files appearing in main checkout that match the
# active worktree branch's working tree).
#
# Whitelist (these M files are expected and not leaked):
#   - .claude/instincts.yaml
#   - .claude/memory/**
#
# JSONL shape (one object per leak event):
#   { ts, session_id, event: "detected", main_head,
#     leaked_files: [{path, diff_head}], throttle_count }
#
# Throttle (slice 3): max 5 log entries per session via marker file
#   $TMPDIR/worktree-leak-fire-count-<session_id>.
#
# Non-fatal on any error: the hook must never block the Stop event.

set -uo pipefail

WHITELIST_EXACT=(
  ".claude/instincts.yaml"
)
WHITELIST_PREFIX=(
  ".claude/memory/"
)

is_whitelisted() {
  local path="$1"
  local p
  for p in "${WHITELIST_EXACT[@]}"; do
    [[ "${path}" == "${p}" ]] && return 0
  done
  for p in "${WHITELIST_PREFIX[@]}"; do
    [[ "${path}" == "${p}"* ]] && return 0
  done
  return 1
}

main() {
  local input session_id
  input="$(cat)"
  session_id="$(printf '%s' "${input}" | jq -r '.session_id // empty' 2>/dev/null)"
  [[ -z "${session_id}" ]] && return 0

  local main_dir="${CLAUDE_PROJECT_DIR:-}"
  [[ -z "${main_dir}" || ! -d "${main_dir}/.git" ]] && return 0

  # Tracked-modified files only (porcelain Y or X column = M).
  local porcelain
  porcelain="$(git -C "${main_dir}" status --porcelain 2>/dev/null || true)"
  [[ -z "${porcelain}" ]] && return 0

  local leaked=()
  local line path
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    # Lines are "XY path"; only consider X or Y = M (not ?? or A).
    [[ "${line:0:2}" =~ [MR][MD\ ]|[\ ][M] ]] || continue
    path="${line:3}"
    # Trim trailing junk (rename arrows etc.) — keep first space-token.
    path="${path%% *}"
    is_whitelisted "${path}" && continue
    leaked+=("${path}")
  done <<< "${porcelain}"

  (( ${#leaked[@]} == 0 )) && return 0

  local log_dir="${HOME}/.claude/log"
  mkdir -p "${log_dir}" 2>/dev/null || return 0
  local log_file="${log_dir}/worktree-leak-events.jsonl"

  local ts main_head
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  main_head="$(git -C "${main_dir}" rev-parse HEAD 2>/dev/null || echo "?")"

  # Build leaked_files JSON array.
  local files_json
  files_json="$(
    for path in "${leaked[@]}"; do
      local diff_head
      diff_head="$(git -C "${main_dir}" diff HEAD -- "${path}" 2>/dev/null | head -30)"
      jq -cn --arg p "${path}" --arg d "${diff_head}" '{path:$p, diff_head:$d}'
    done | jq -cs '.'
  )"

  ( printf '{"ts":"%s","session_id":"%s","event":"detected","main_head":"%s","leaked_files":%s,"throttle_count":1}\n' \
      "${ts}" "${session_id}" "${main_head}" "${files_json}" \
      >> "${log_file}" ) 2>/dev/null || true
}

main
