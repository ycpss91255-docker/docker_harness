#!/usr/bin/env bats

load '../lib/test_helper'

@test "fires on standalone shellcheck" {
  run "$(hook remind_docker_for_lint.sh)" <<< '{"tool_input":{"command":"shellcheck script/foo.sh"}}'
  assert_message_contains "驗證一律走 Docker"
}

@test "fires on standalone bats" {
  run "$(hook remind_docker_for_lint.sh)" <<< '{"tool_input":{"command":"bats test/unit/foo_spec.bats"}}'
  assert_message_contains "驗證一律走 Docker"
}

@test "fires on standalone hadolint" {
  run "$(hook remind_docker_for_lint.sh)" <<< '{"tool_input":{"command":"hadolint Dockerfile"}}'
  assert_message_contains "驗證一律走 Docker"
}

@test "silent inside docker run wrapper" {
  run "$(hook remind_docker_for_lint.sh)" <<< '{"tool_input":{"command":"docker run --rm img shellcheck foo.sh"}}'
  assert_silent
}

@test "silent inside ./build.sh test wrapper" {
  run "$(hook remind_docker_for_lint.sh)" <<< '{"tool_input":{"command":"./build.sh test"}}'
  assert_silent
}

@test "silent inside make -f Makefile.ci wrapper (legacy, transition-tolerated)" {
  run "$(hook remind_docker_for_lint.sh)" <<< '{"tool_input":{"command":"make -f Makefile.ci lint"}}'
  assert_silent
}

@test "silent inside just -f justfile.ci wrapper (base#573 make->just, #202)" {
  run "$(hook remind_docker_for_lint.sh)" <<< '{"tool_input":{"command":"just -f justfile.ci lint"}}'
  assert_silent
}

@test "silent inside just test wrapper (downstream container-ops)" {
  run "$(hook remind_docker_for_lint.sh)" <<< '{"tool_input":{"command":"just test"}}'
  assert_silent
}

@test "silent on unrelated command containing the word bats in path" {
  run "$(hook remind_docker_for_lint.sh)" <<< '{"tool_input":{"command":"ls /usr/lib/bats-core"}}'
  assert_silent
}

@test "silent inside make -C .claude/test wrapper (default list)" {
  run "$(hook remind_docker_for_lint.sh)" <<< '{"tool_input":{"command":"make -C .claude/test test"}}'
  assert_silent
}

@test "lint_wrappers.txt overrides default list" {
  local repo
  repo="$(mktemp -d)"
  mkdir -p "${repo}/.claude"
  printf '%s\n' "make -C .claude" "my-wrapper" > "${repo}/.claude/lint_wrappers.txt"
  CLAUDE_PROJECT_DIR="${repo}" \
    run "$(hook remind_docker_for_lint.sh)" <<< '{"tool_input":{"command":"my-wrapper bats foo.bats"}}'
  assert_silent
  rm -rf "${repo}"
}

@test "lint_wrappers.txt override drops the default docker pattern" {
  # With default wrappers, the "docker run" prefix matches and silences;
  # with override = ["make -C .claude"], no wrapper matches, so the
  # boundary regex catches "; bats" and fires.
  local repo
  repo="$(mktemp -d)"
  mkdir -p "${repo}/.claude"
  echo "make -C .claude" > "${repo}/.claude/lint_wrappers.txt"
  CLAUDE_PROJECT_DIR="${repo}" \
    run "$(hook remind_docker_for_lint.sh)" <<< '{"tool_input":{"command":"docker run img echo hi; bats foo"}}'
  assert_message_contains "驗證一律走 Docker"
  rm -rf "${repo}"
}

@test "lint_wrappers.txt ignores blank and # comment lines" {
  local repo
  repo="$(mktemp -d)"
  mkdir -p "${repo}/.claude"
  printf '%s\n' "" "# comment" "  " "make -C .claude" > "${repo}/.claude/lint_wrappers.txt"
  CLAUDE_PROJECT_DIR="${repo}" \
    run "$(hook remind_docker_for_lint.sh)" <<< '{"tool_input":{"command":"make -C .claude bats-host test"}}'
  assert_silent
  rm -rf "${repo}"
}

@test "missing CLAUDE_PROJECT_DIR falls back to default list" {
  unset CLAUDE_PROJECT_DIR
  run "$(hook remind_docker_for_lint.sh)" <<< '{"tool_input":{"command":"docker run img shellcheck foo.sh"}}'
  assert_silent
}
