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

@test "silent when git pull but no M files at all" {
  local repo
  repo="$(mktemp_repo)"

  CLAUDE_PROJECT_DIR="${repo}" run "$(hook auto_clean_worktree_leak.sh)" \
    <<< "$(mk_input "git pull --ff-only origin main" "${repo}" s-2)"
  assert_success

  local log="${HOME}/.claude/log/worktree-leak-events.jsonl"
  [[ ! -f "${log}" ]] || { echo "log should not exist; got:"; cat "${log}"; return 1; }
}

@test "silent when only whitelisted M (no checkout HEAD, no log)" {
  local repo
  repo="$(mktemp_repo)"
  mkdir -p "${repo}/.claude/memory"
  echo "v1" > "${repo}/.claude/memory/feedback.md"
  git -C "${repo}" add .claude/memory/feedback.md
  git -C "${repo}" commit -q -m "add memory"
  echo "v2 user-edit" > "${repo}/.claude/memory/feedback.md"

  CLAUDE_PROJECT_DIR="${repo}" run "$(hook auto_clean_worktree_leak.sh)" \
    <<< "$(mk_input "git pull --ff-only origin main" "${repo}" s-3)"
  assert_success

  # Memory file preserved (not checkout'd).
  [[ "$(cat "${repo}/.claude/memory/feedback.md")" == "v2 user-edit" ]] \
    || { echo "whitelist file should not be reset"; return 1; }
  local log="${HOME}/.claude/log/worktree-leak-events.jsonl"
  [[ ! -f "${log}" ]] || { echo "log should not exist; got:"; cat "${log}"; return 1; }
}

@test "non-trigger command passes through (git status, git log, etc.)" {
  local repo
  repo="$(mktemp_repo)"
  echo "leaked" > "${repo}/script/foo.sh"

  CLAUDE_PROJECT_DIR="${repo}" run "$(hook auto_clean_worktree_leak.sh)" \
    <<< "$(mk_input "git status" "${repo}" s-4)"
  assert_success

  # File NOT restored: the hook should not fire on git status.
  [[ "$(cat "${repo}/script/foo.sh")" == "leaked" ]] \
    || { echo "file should be untouched for git status; got: $(cat "${repo}/script/foo.sh")"; return 1; }
  local log="${HOME}/.claude/log/worktree-leak-events.jsonl"
  [[ ! -f "${log}" ]] || { echo "log should not exist; got:"; cat "${log}"; return 1; }
}
