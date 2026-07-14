#!/usr/bin/env bats

load '../lib/test_helper'

# Stop hook: scans LAST assistant message of the transcript for
# off-task-suggestion phrases (breaks / meals / wellness / schedule).
# Emits systemMessage when matched; silent otherwise. Throttled once
# per session per matched phrase via TMPDIR marker.

setup() {
  TRANSCRIPT="$(mktemp)"
  MARKER_TMP="$(mktemp -d)"
  export TMPDIR="${MARKER_TMP}"
}

teardown() {
  rm -f "${TRANSCRIPT}"
  rm -rf "${MARKER_TMP}"
}

emit_assistant() {
  jq -nc --arg t "$1" '{
    message: { role: "assistant", content: $t }
  }' >> "${TRANSCRIPT}"
}

emit_user() {
  jq -nc --arg t "$1" '{
    message: { role: "user", content: $t }
  }' >> "${TRANSCRIPT}"
}

run_hook() {
  local stop_active="${1:-false}"
  local input
  input="$(jq -nc --arg t "${TRANSCRIPT}" --arg s sess109 --argjson sa "${stop_active}" '{
    transcript_path: $t,
    session_id: $s,
    stop_hook_active: $sa
  }')"
  run "$(hook check_no_off_task_suggestions.sh)" <<< "${input}"
}

@test "silent on empty transcript" {
  run_hook
  assert_silent
}

@test "silent on clean technical message" {
  emit_user "Run the tests"
  emit_assistant "Tests pass. Next up: open the PR."
  run_hook
  assert_silent
}

@test "fires on 'stop for dinner?'" {
  emit_assistant "Done. Want to continue with #91? Or stop for dinner?"
  run_hook
  assert_success
  assert_output --partial "Off-task suggestion"
  assert_output --partial "stop for dinner"
}

@test "fires on 'take a break?'" {
  emit_assistant "Three more issues left. Want to take a break?"
  run_hook
  assert_success
  assert_output --partial "Off-task suggestion"
  assert_output --partial "take a break"
}

@test "fires on 'need some rest?'" {
  emit_assistant "Long session. Need some rest?"
  run_hook
  assert_success
  assert_output --partial "Off-task suggestion"
}

@test "fires on 'do it tomorrow?'" {
  emit_assistant "Heavy lift. Do it tomorrow?"
  run_hook
  assert_success
  assert_output --partial "Off-task suggestion"
}

@test "case-insensitive match ('Stop For Dinner')" {
  emit_assistant "Done. Stop For Dinner?"
  run_hook
  assert_success
  assert_output --partial "Off-task suggestion"
}

@test "scans only LAST assistant message (earlier hits ignored)" {
  emit_assistant "Want to take a break?"
  emit_user "no, keep going"
  emit_assistant "Tests pass. Next up: open the PR."
  run_hook
  assert_silent
}

@test "throttled: same phrase fires once per session" {
  emit_assistant "Done. Stop for dinner?"
  run_hook
  assert_output --partial "Off-task suggestion"
  run_hook
  assert_silent
}

@test "stop_hook_active=true skips" {
  emit_assistant "Stop for dinner?"
  run_hook true
  assert_silent
}

@test "NO_OFF_TASK_REMIND_DISABLE=1 skips" {
  emit_assistant "Stop for dinner?"
  NO_OFF_TASK_REMIND_DISABLE=1 run_hook
  assert_silent
}
