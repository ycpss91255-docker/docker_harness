#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  HOME_DIR="$(mktemp -d)"
  export HOME="${HOME_DIR}"
  TMPDIR_OVERRIDE="${HOME_DIR}/tmp"
  export TMPDIR="${TMPDIR_OVERRIDE}"
  mkdir -p "${TMPDIR_OVERRIDE}"
}

teardown() {
  rm -rf "${HOME_DIR}"
}

mk_input() {
  local cmd="$1" cwd="$2" session_id="${3:-test-sess}"
  jq -cn --arg c "${cmd}" --arg d "${cwd}" --arg s "${session_id}" \
    '{tool_input:{command:$c}, hook_event_name:"PreToolUse", cwd:$d, session_id:$s}'
}

@test "git pull with unwhitelisted M triggers checkout HEAD + cleaned log entry" {
  local repo
  repo="$(mktemp_repo)"
  echo "leaked" > "${repo}/script/foo.sh"

  CLAUDE_PROJECT_DIR="${repo}" run "$(hook auto_clean_worktree_leak.sh)" \
    <<< "$(mk_input "git pull --ff-only origin main" "${repo}" s-1)"
  assert_success

  # File restored to HEAD content.
  [[ "$(cat "${repo}/script/foo.sh")" == "echo init" ]] \
    || { echo "file content not restored: $(cat "${repo}/script/foo.sh")"; return 1; }

  # cleaned event in log.
  local log="${HOME}/.claude/log/worktree-leak-events.jsonl"
  [[ -f "${log}" ]] || { echo "log not at ${log}"; return 1; }
  jq -e '.event == "cleaned" and (.leaked_files[0].path == "script/foo.sh")' "${log}" >/dev/null \
    || { echo "schema mismatch:"; cat "${log}"; return 1; }
}
