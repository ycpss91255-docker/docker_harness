#!/usr/bin/env bats

load '../lib/test_helper'

@test "fires on gh pr create -> auto-merge-on-green" {
  run "$(hook remind_ci_auto_merge.sh)" <<< '{"tool_input":{"command":"gh pr create --title foo --body bar"}}'
  assert_message_contains "auto-merge-on-green"
}

@test "fires on chained command containing gh pr create" {
  run "$(hook remind_ci_auto_merge.sh)" <<< '{"tool_input":{"command":"git push -u origin foo && gh pr create --fill"}}'
  assert_message_contains "auto-merge-on-green"
}

@test "silent on gh pr list" {
  run "$(hook remind_ci_auto_merge.sh)" <<< '{"tool_input":{"command":"gh pr list"}}'
  assert_silent
}

@test "silent on git push (owned by remind_monitor_on_git_push)" {
  run "$(hook remind_ci_auto_merge.sh)" <<< '{"tool_input":{"command":"git push origin feat/x"}}'
  assert_silent
}

@test "silent on unrelated command" {
  run "$(hook remind_ci_auto_merge.sh)" <<< '{"tool_input":{"command":"echo hello"}}'
  assert_silent
}

@test "silent on empty command" {
  run "$(hook remind_ci_auto_merge.sh)" <<< '{"tool_input":{}}'
  assert_silent
}
