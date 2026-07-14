#!/usr/bin/env bats

load '../lib/test_helper'

@test "fires on gh repo create ycpss91255-docker/<name>" {
  run "$(hook remind_topics_yaml_on_new_repo.sh)" <<< '{"tool_input":{"command":"gh repo create ycpss91255-docker/foo --public"}}'
  assert_message_contains "topics.yaml"
}

@test "fires regardless of gh repo create flag order" {
  run "$(hook remind_topics_yaml_on_new_repo.sh)" <<< '{"tool_input":{"command":"gh repo create --public ycpss91255-docker/bar"}}'
  assert_message_contains "topics.yaml"
}

@test "silent on gh repo create against another org" {
  run "$(hook remind_topics_yaml_on_new_repo.sh)" <<< '{"tool_input":{"command":"gh repo create other-org/foo --public"}}'
  assert_silent
}

@test "silent on gh repo view (not create)" {
  run "$(hook remind_topics_yaml_on_new_repo.sh)" <<< '{"tool_input":{"command":"gh repo view ycpss91255-docker/foo"}}'
  assert_silent
}

@test "silent on unrelated command" {
  run "$(hook remind_topics_yaml_on_new_repo.sh)" <<< '{"tool_input":{"command":"ls"}}'
  assert_silent
}

@test "silent when tool_input.command missing" {
  run "$(hook remind_topics_yaml_on_new_repo.sh)" <<< '{"tool_input":{}}'
  assert_silent
}
