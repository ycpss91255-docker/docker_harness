#!/usr/bin/env bats

load '../lib/test_helper'

# Stop hook: reads transcript_path JSONL, counts rationale-shaped
# messages, emits a systemMessage if threshold reached AND no
# doc/adr/ Write/Edit happened this session.

setup() {
  TRANSCRIPT="$(mktemp)"
  MARKER_TMP="$(mktemp -d)"
  export TMPDIR="${MARKER_TMP}"
}

teardown() {
  rm -f "${TRANSCRIPT}"
  rm -rf "${MARKER_TMP}"
}

# Append a JSONL message line to the transcript.
# emit_text <role> <text>
emit_text() {
  local role="$1" text="$2"
  jq -nc --arg r "${role}" --arg t "${text}" '{
    message: { role: $r, content: $t }
  }' >> "${TRANSCRIPT}"
}

# emit_tool_use <Write|Edit|MultiEdit> <file_path>
emit_tool_use() {
  local name="$1" file_path="$2"
  jq -nc --arg n "${name}" --arg f "${file_path}" '{
    message: {
      role: "assistant",
      content: [{ type: "tool_use", name: $n, input: { file_path: $f } }]
    }
  }' >> "${TRANSCRIPT}"
}

# run_hook -- send Stop event JSON to the hook with our transcript.
run_hook() {
  local stop_active="${1:-false}"
  local input
  input="$(jq -nc --arg t "${TRANSCRIPT}" --arg s sess123 --argjson sa "${stop_active}" '{
    transcript_path: $t,
    session_id: $s,
    stop_hook_active: $sa
  }')"
  run "$(hook remind_adr_on_design_decision.sh)" <<< "${input}"
}

@test "silent on empty transcript" {
  run_hook
  assert_silent
}

@test "silent with one rationale hit (below threshold)" {
  emit_text user "Should we go with this alternative?"
  run_hook
  assert_silent
}

@test "fires with 3 rationale hits (threshold met)" {
  emit_text user "What are the alternatives here?"
  emit_text assistant "The trade-off is between X and Y."
  emit_text user "Why not Z instead? We need to decide."
  emit_text assistant "We'll go with X. Z is rejected because of latency."
  run_hook
  assert_success
  assert_output --partial "ADR reminder"
  assert_output --partial "/adr <slug>"
}

@test "silent when doc/adr/ Write happened in same session" {
  emit_text user "Lots of alternatives to consider here."
  emit_text assistant "The trade-off favours X. Rejected because: Y is slow."
  emit_text user "Why not Z?"
  emit_text assistant "Going with X. Decided to ship this week."
  emit_tool_use Write "/work/doc/adr/00000005-x-over-y.md"
  run_hook
  assert_silent
}

@test "silent when stop_hook_active=true (re-entry guard)" {
  emit_text user "alternatives trade-off rejected because"
  emit_text assistant "going with decided to"
  emit_text user "why not"
  run_hook true
  assert_silent
}

@test "silent when ADR_REMIND_DISABLE=1" {
  emit_text user "alternatives trade-off rejected because"
  emit_text assistant "going with decided to"
  emit_text user "why not"
  ADR_REMIND_DISABLE=1 run_hook
  assert_silent
}

@test "rationale match is case-insensitive" {
  emit_text user "ALTERNATIVES are X and Y"
  emit_text assistant "Trade-Off here is throughput"
  emit_text user "We DECIDED TO ship anyway"
  run_hook
  assert_success
  assert_output --partial "ADR reminder"
}

@test "custom threshold via env" {
  emit_text user "alternative one"
  emit_text assistant "alternative two"
  ADR_REMIND_THRESHOLD=2 run_hook
  assert_success
  assert_output --partial "ADR reminder"
}

@test "Edit (not just Write) on doc/adr/ also counts as ADR activity" {
  emit_text user "alternatives trade-off rejected because"
  emit_text assistant "why not going with decided to"
  emit_text user "out of scope because"
  emit_tool_use Edit "/work/doc/adr/00000005-x-over-y.md"
  run_hook
  assert_silent
}

@test "non-ADR Write does not suppress the nudge" {
  emit_text user "alternatives trade-off rejected because"
  emit_text assistant "why not going with decided to"
  emit_text user "out of scope because"
  emit_tool_use Write "/work/src/main.go"
  run_hook
  assert_success
  assert_output --partial "ADR reminder"
}

@test "throttle: second fire with same signal-bucket silent" {
  emit_text user "alternatives trade-off rejected because"
  emit_text assistant "why not going with decided to"
  emit_text user "out of scope because"
  run_hook
  assert_success
  assert_output --partial "ADR reminder"
  # Second invocation with the same signal-set should be silent
  # (throttle marker dropped in TMPDIR).
  run_hook
  assert_silent
}

@test "silent on missing transcript_path" {
  local input
  input='{"session_id":"sess123","stop_hook_active":false}'
  run "$(hook remind_adr_on_design_decision.sh)" <<< "${input}"
  assert_silent
}
