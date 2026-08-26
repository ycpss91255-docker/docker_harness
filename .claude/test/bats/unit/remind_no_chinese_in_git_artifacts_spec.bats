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

# #283 defect 2: the rule applies to the git artifact being written, not to
# any command that mentions one. A git/gh named inside another command's
# quoted argument is a string, so CJK there is not a commit message.

@test "silent on echo whose quoted argument mentions git commit and holds CJK" {
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< '{"tool_input":{"command":"echo \"reminder: git commit -m must be English 中文\""}}'
  assert_silent
}

# #283 defect 2, third surface: scoping to one command must not lose the
# rest of THAT command -- a backslash-continued newline is a continuation,
# so the message on the next line is still the commit message.

@test "denies a backslash-continued git commit whose CJK message is on a later line" {
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< '{"tool_input":{"command":"git commit \\\n  -m \"修正錯誤\""}}'
  assert_permission_decision "deny"
}

@test "silent on a backslash-continued echo mentioning git commit with CJK" {
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< '{"tool_input":{"command":"echo one \\\n  \"reminder about git commit -m 中文\""}}'
  assert_silent
}

# #283 defect 2, second surface: heredoc body content is data the command
# writes, so CJK there is not a commit message either -- while a genuine
# git commit on its own line after the heredoc still is one.

@test "silent on a heredoc body holding CJK and a git commit line" {
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< '{"tool_input":{"command":"cat > /tmp/fixture.txt <<EOF\ngit commit -m \"修正錯誤\"\nEOF"}}'
  assert_silent
}

@test "denies a real git commit with CJK on a line after a heredoc block" {
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< '{"tool_input":{"command":"cat > /tmp/fixture.txt <<EOF\nplain notes\nEOF\ngit commit -m \"修正錯誤\""}}'
  assert_permission_decision "deny"
}

@test "denies a real git commit with CJK chained after an unrelated echo" {
  run "$(hook remind_no_chinese_in_git_artifacts.sh)" \
    <<< '{"tool_input":{"command":"echo staging && git commit -m \"修正錯誤\""}}'
  assert_permission_decision "deny"
}
