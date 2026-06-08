#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  HOME_DIR="$(mktemp -d)"
  export HOME="${HOME_DIR}"
  # Isolate throttle marker per test.
  TMPDIR_OVERRIDE="${HOME_DIR}/tmp"
  export TMPDIR="${TMPDIR_OVERRIDE}"
  mkdir -p "${TMPDIR_OVERRIDE}"
}

teardown() {
  rm -rf "${HOME_DIR}"
}

mk_input() {
  local session_id="${1:-test-sess}"
  printf '{"session_id":"%s","hook_event_name":"Stop"}\n' "${session_id}"
}

@test "writes JSONL entry when M file outside whitelist exists in main checkout" {
  local repo
  repo="$(mktemp_repo)"
  # Modify a tracked file outside whitelist.
  echo "leak-modified" > "${repo}/script/foo.sh"

  CLAUDE_PROJECT_DIR="${repo}" run "$(hook forensic_worktree_leak.sh)" <<< "$(mk_input s-1)"
  assert_success

  local log="${HOME}/.claude/log/worktree-leak-events.jsonl"
  [[ -f "${log}" ]] || { echo "log not at ${log}"; return 1; }
  jq -e '
    .session_id == "s-1"
    and .event == "detected"
    and (.leaked_files | length) > 0
    and (.leaked_files[0].path == "script/foo.sh")
  ' "${log}" >/dev/null || { echo "schema mismatch:"; cat "${log}"; return 1; }
}
