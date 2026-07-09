#!/usr/bin/env bats

load '../lib/test_helper'

@test "fires on git commit -m with Co-Authored-By: Claude" {
  run "$(hook remind_no_ai_attribution.sh)" <<< '{"tool_input":{"command":"git commit -m \"feat: x\\n\\nCo-Authored-By: Claude <noreply@anthropic.com>\""}}'
  assert_message_contains "AI 歸屬標記"
}

@test "fires on gh pr create with Generated with [Claude Code]" {
  run "$(hook remind_no_ai_attribution.sh)" <<< '{"tool_input":{"command":"gh pr create --body \"summary\\n\\nGenerated with [Claude Code]\""}}'
  assert_message_contains "AI 歸屬標記"
}

@test "fires on gh issue comment with attribution" {
  run "$(hook remind_no_ai_attribution.sh)" <<< '{"tool_input":{"command":"gh issue comment 1 --body \"Co-Authored-By: Claude\""}}'
  assert_message_contains "AI 歸屬標記"
}

@test "silent on git commit without attribution" {
  run "$(hook remind_no_ai_attribution.sh)" <<< '{"tool_input":{"command":"git commit -m \"feat: x\""}}'
  assert_silent
}

@test "silent on non-git/gh command containing attribution string" {
  run "$(hook remind_no_ai_attribution.sh)" <<< '{"tool_input":{"command":"echo Co-Authored-By: Claude"}}'
  assert_silent
}
