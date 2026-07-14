#!/usr/bin/env bats

load '../lib/test_helper'

@test "fires on gh run rerun (PR + tag hints)" {
  run "$(hook remind_monitor_on_ci_trigger.sh)" <<< '{"tool_input":{"command":"gh run rerun 1234567890"}}'
  assert_message_contains "wait-pr-ci"
  assert_message_contains "wait-tag-ci"
}

@test "fires on gh run rerun --failed" {
  run "$(hook remind_monitor_on_ci_trigger.sh)" <<< '{"tool_input":{"command":"gh run rerun 1234567890 --failed"}}'
  assert_message_contains "wait-pr-ci"
}

@test "fires on gh workflow run (tag-scoped hint)" {
  run "$(hook remind_monitor_on_ci_trigger.sh)" <<< '{"tool_input":{"command":"gh workflow run release.yaml"}}'
  assert_message_contains "wait-tag-ci"
}

@test "fires on gh workflow run --ref refs/heads/main" {
  run "$(hook remind_monitor_on_ci_trigger.sh)" <<< '{"tool_input":{"command":"gh workflow run release.yaml --ref refs/heads/main"}}'
  assert_message_contains "wait-tag-ci"
}

@test "fires on chained command containing gh workflow run" {
  run "$(hook remind_monitor_on_ci_trigger.sh)" <<< '{"tool_input":{"command":"git push origin v0.1.0 && gh workflow run release.yaml --ref v0.1.0"}}'
  assert_message_contains "wait-tag-ci"
}

@test "fires on chained command containing gh run rerun" {
  run "$(hook remind_monitor_on_ci_trigger.sh)" <<< '{"tool_input":{"command":"gh pr checks 42 ; gh run rerun 1234567890 --failed"}}'
  assert_message_contains "wait-pr-ci"
}

@test "silent on gh run list" {
  run "$(hook remind_monitor_on_ci_trigger.sh)" <<< '{"tool_input":{"command":"gh run list"}}'
  assert_silent
}

@test "silent on gh run view" {
  run "$(hook remind_monitor_on_ci_trigger.sh)" <<< '{"tool_input":{"command":"gh run view 1234567890"}}'
  assert_silent
}

@test "silent on gh run watch" {
  run "$(hook remind_monitor_on_ci_trigger.sh)" <<< '{"tool_input":{"command":"gh run watch 1234567890"}}'
  assert_silent
}

@test "silent on gh workflow list" {
  run "$(hook remind_monitor_on_ci_trigger.sh)" <<< '{"tool_input":{"command":"gh workflow list"}}'
  assert_silent
}

@test "silent on gh workflow view" {
  run "$(hook remind_monitor_on_ci_trigger.sh)" <<< '{"tool_input":{"command":"gh workflow view test.yaml"}}'
  assert_silent
}

@test "silent on unrelated command" {
  run "$(hook remind_monitor_on_ci_trigger.sh)" <<< '{"tool_input":{"command":"echo hello"}}'
  assert_silent
}

@test "silent on empty command" {
  run "$(hook remind_monitor_on_ci_trigger.sh)" <<< '{"tool_input":{}}'
  assert_silent
}
