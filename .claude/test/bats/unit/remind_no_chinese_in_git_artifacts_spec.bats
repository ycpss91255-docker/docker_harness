#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMPDIR}"
}

@test "denies git commit -m with CJK ideograph" {
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< '{"tool_input":{"command":"git commit -m \"修了一個 bug\""}}'
  assert_permission_decision "deny"
  assert_output --partial "CJK or fullwidth"
}

@test "denies gh pr create --body with fullwidth comma" {
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< '{"tool_input":{"command":"gh pr create --title T --body \"a，b\""}}'
  assert_permission_decision "deny"
}

@test "denies gh issue create --body with fullwidth digit" {
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< '{"tool_input":{"command":"gh issue create --title test --body \"v１.0\""}}'
  assert_permission_decision "deny"
}

@test "denies gh issue close --comment with CJK punctuation" {
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< '{"tool_input":{"command":"gh issue close 5 --comment \"done。\""}}'
  assert_permission_decision "deny"
}

@test "denies gh pr comment --body-file pointing at file with CJK" {
  printf 'fix: \xe4\xb8\xad\xe6\x96\x87\n' > "${TMPDIR}/body.md"
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< "{\"tool_input\":{\"command\":\"gh pr comment 1 --body-file ${TMPDIR}/body.md\"}}"
  assert_permission_decision "deny"
  assert_output --partial "${TMPDIR}/body.md"
}

@test "silent on gh pr create --body-file pointing at README.zh-TW.md (exempt)" {
  printf '# 中文標題\n說明\n' > "${TMPDIR}/README.zh-TW.md"
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< "{\"tool_input\":{\"command\":\"gh pr create --title T --body-file ${TMPDIR}/README.zh-TW.md\"}}"
  assert_silent
}

@test "silent on gh issue create --body-file pointing at i18n.sh (exempt)" {
  printf 'msg() { echo "中文"; }\n' > "${TMPDIR}/i18n.sh"
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< "{\"tool_input\":{\"command\":\"gh issue create --title T --body-file ${TMPDIR}/i18n.sh\"}}"
  assert_silent
}

@test "silent on git commit -m with plain English" {
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< '{"tool_input":{"command":"git commit -m \"fix: typo in setup script\""}}'
  assert_silent
}

@test "silent on git commit -m with em-dash and smart quotes (English typography)" {
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< '{"tool_input":{"command":"git commit -m \"fix: A — B with “quotes”\""}}'
  assert_silent
}

@test "silent on non-git/gh command containing CJK" {
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< '{"tool_input":{"command":"echo \"中文\""}}'
  assert_silent
}

@test "silent on gh pr list --json (no body/title editing)" {
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< '{"tool_input":{"command":"gh pr list --repo a/b --json title"}}'
  assert_silent
}
