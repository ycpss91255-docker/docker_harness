#!/usr/bin/env bats

load '../lib/test_helper'

# stage_files <repo> <file1> [<file2> ...] — write empty file at <repo>/<f>
# (creating dirs as needed) and `git add` it.
stage_files() {
  local repo="$1"
  shift
  local f
  for f in "$@"; do
    mkdir -p "${repo}/$(dirname "${f}")"
    : > "${repo}/${f}"
    git -C "${repo}" add -- "${f}" >/dev/null
  done
}

# run_hook <cmd> <cwd> — pipe the PreToolUse JSON to the hook.
run_hook() {
  local cmd="$1"
  local cwd="$2"
  local payload
  payload="$(jq -n --arg c "${cmd}" --arg d "${cwd}" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$d}')"
  run bash -c "printf '%s' \"\$1\" | $(hook remind_readme_on_core_script.sh)" \
    bash "${payload}"
}

@test "non-git-commit command is silent" {
  local repo
  repo="$(mktemp_repo)"
  run_hook "ls -la" "${repo}"
  assert_silent
}

@test "git status is silent (not a commit)" {
  local repo
  repo="$(mktemp_repo)"
  run_hook "git status" "${repo}"
  assert_silent
}

@test "git commit --amend is silent" {
  local repo
  repo="$(mktemp_repo)"
  stage_files "${repo}" ".base/upgrade.sh"
  run_hook "git commit --amend -m fix" "${repo}"
  assert_silent
}

@test "git commit with no staged files is silent" {
  local repo
  repo="$(mktemp_repo)"
  run_hook "git commit -m foo" "${repo}"
  assert_silent
}

@test "git commit with only README staged is silent" {
  local repo
  repo="$(mktemp_repo)"
  stage_files "${repo}" "README.md"
  run_hook "git commit -m docs" "${repo}"
  assert_silent
}

@test "git commit with build.sh (non-core script) is silent" {
  local repo
  repo="$(mktemp_repo)"
  stage_files "${repo}" "build.sh"
  run_hook "git commit -m fix" "${repo}"
  assert_silent
}

@test "git commit with .base/upgrade.sh and no README fires" {
  local repo
  repo="$(mktemp_repo)"
  stage_files "${repo}" ".base/upgrade.sh"
  run_hook "git commit -m feat" "${repo}"
  assert_message_contains "README drift"
  assert_message_contains ".base/upgrade.sh"
}

@test "git commit with .base/init.sh and no README fires" {
  local repo
  repo="$(mktemp_repo)"
  stage_files "${repo}" ".base/init.sh"
  run_hook "git commit -m feat" "${repo}"
  assert_message_contains "README drift"
}

@test "git commit with .base/script/docker/setup.sh and no README fires" {
  local repo
  repo="$(mktemp_repo)"
  stage_files "${repo}" ".base/script/docker/setup.sh"
  run_hook "git commit -m feat" "${repo}"
  assert_message_contains "README drift"
}

@test "git commit with upgrade.sh (template-internal session, no prefix) fires" {
  local repo
  repo="$(mktemp_repo)"
  stage_files "${repo}" "upgrade.sh"
  run_hook "git commit -m feat" "${repo}"
  assert_message_contains "README drift"
}

@test "git commit with core script + README is silent" {
  local repo
  repo="$(mktemp_repo)"
  stage_files "${repo}" ".base/upgrade.sh" "README.md"
  run_hook "git commit -m feat" "${repo}"
  assert_silent
}

@test "git commit with core script + translated README is silent" {
  local repo
  repo="$(mktemp_repo)"
  stage_files "${repo}" ".base/upgrade.sh" "README.zh-TW.md"
  run_hook "git commit -m feat" "${repo}"
  assert_silent
}

@test "git -C <path> commit resolves work dir from -C" {
  local repo
  repo="$(mktemp_repo)"
  stage_files "${repo}" ".base/upgrade.sh"
  run_hook "git -C ${repo} commit -m feat" "/tmp"
  assert_message_contains "README drift"
}
