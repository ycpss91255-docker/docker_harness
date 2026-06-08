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

@test "silent when only whitelisted M files modified (.claude/memory/**)" {
  local repo
  repo="$(mktemp_repo)"
  mkdir -p "${repo}/.claude/memory"
  echo "initial" > "${repo}/.claude/memory/feedback_X.md"
  git -C "${repo}" add .claude/memory/feedback_X.md
  git -C "${repo}" commit -q -m "add memory"
  echo "user-modified" > "${repo}/.claude/memory/feedback_X.md"

  CLAUDE_PROJECT_DIR="${repo}" run "$(hook forensic_worktree_leak.sh)" <<< "$(mk_input s-2)"
  assert_success

  local log="${HOME}/.claude/log/worktree-leak-events.jsonl"
  [[ ! -f "${log}" ]] || { echo "log should not exist; got:"; cat "${log}"; return 1; }
}

@test "silent when only whitelisted M file modified (.claude/instincts.yaml)" {
  local repo
  repo="$(mktemp_repo)"
  mkdir -p "${repo}/.claude"
  echo "rules:" > "${repo}/.claude/instincts.yaml"
  git -C "${repo}" add .claude/instincts.yaml
  git -C "${repo}" commit -q -m "add instincts"
  echo "rules: edited" > "${repo}/.claude/instincts.yaml"

  CLAUDE_PROJECT_DIR="${repo}" run "$(hook forensic_worktree_leak.sh)" <<< "$(mk_input s-3)"
  assert_success

  local log="${HOME}/.claude/log/worktree-leak-events.jsonl"
  [[ ! -f "${log}" ]] || { echo "log should not exist; got:"; cat "${log}"; return 1; }
}
