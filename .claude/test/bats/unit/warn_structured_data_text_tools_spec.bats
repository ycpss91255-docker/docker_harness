#!/usr/bin/env bats

load '../lib/test_helper'

@test "fires on awk parsing a .jsonl file" {
  run "$(hook warn_structured_data_text_tools.sh)" <<< '{"tool_input":{"command":"awk '\''{print $1}'\'' transcript.jsonl"}}'
  assert_message_contains "fragile"
}

@test "fires on sed parsing a .json file" {
  run "$(hook warn_structured_data_text_tools.sh)" <<< '{"tool_input":{"command":"sed -n 1p data.json"}}'
  assert_message_contains "fragile"
}

@test "fires on cat .jsonl piped to awk" {
  run "$(hook warn_structured_data_text_tools.sh)" <<< '{"tool_input":{"command":"cat x.jsonl | awk '\''{c++} END{print c}'\''"}}'
  assert_message_contains "fragile"
}

@test "fires on chained command: ls && awk on .json" {
  run "$(hook warn_structured_data_text_tools.sh)" <<< '{"tool_input":{"command":"ls && awk '\''{print}'\'' a.json"}}'
  assert_message_contains "fragile"
}

@test "silent when jq is present (jq extracts, awk formats columns)" {
  run "$(hook warn_structured_data_text_tools.sh)" <<< '{"tool_input":{"command":"jq -r .name foo.json | awk '\''{print $1}'\''"}}'
  assert_silent
}

@test "silent on grep against .jsonl (out of scope — grep on json is common)" {
  run "$(hook warn_structured_data_text_tools.sh)" <<< '{"tool_input":{"command":"grep error log.jsonl"}}'
  assert_silent
}

@test "silent on awk against a non-json file (.csv)" {
  run "$(hook warn_structured_data_text_tools.sh)" <<< '{"tool_input":{"command":"awk -F, '\''{print $2}'\'' data.csv"}}'
  assert_silent
}

@test "silent on commit message describing the rule with jq (false-positive guard)" {
  run "$(hook warn_structured_data_text_tools.sh)" <<< '{"tool_input":{"command":"git commit -m \"docs: use jq not awk on json\""}}'
  assert_silent
}

@test "silent on commit message mentioning awk+json without command-position awk" {
  run "$(hook warn_structured_data_text_tools.sh)" <<< '{"tool_input":{"command":"git commit -m \"stop parsing json by hand\""}}'
  assert_silent
}

@test "silent on empty command" {
  run "$(hook warn_structured_data_text_tools.sh)" <<< '{"tool_input":{"command":""}}'
  assert_silent
}
