#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  TX_DIR="$(mktemp -d)"
  export TX_DIR
  export TMPDIR="${TX_DIR}"
  unset STRATEGIC_COMPACT_DISABLE STRATEGIC_COMPACT_TOOL_THRESHOLD
}

teardown() {
  rm -rf "${TX_DIR}"
}

# Build a transcript file with N tool_use entries; append an extra
# `gh pr merge` Bash invocation if PR_MERGE=1.
mk_transcript() {
  local count="$1" pr_merge="${2:-0}"
  local path="${TX_DIR}/transcript.jsonl"
  : > "${path}"
  local i=0
  while (( i < count )); do
    printf '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}\n' >> "${path}"
    i=$((i + 1))
  done
  if (( pr_merge > 0 )); then
    local j=0
    while (( j < pr_merge )); do
      printf '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr merge 90 --auto --squash"}}]}}\n' >> "${path}"
      j=$((j + 1))
    done
  fi
  printf '%s\n' "${path}"
}

mk_input() {
  local tx="$1" session_id="${2:-test-session}" stop_active="${3:-false}"
  printf '{"transcript_path":"%s","session_id":"%s","stop_hook_active":%s,"hook_event_name":"Stop"}\n' \
    "${tx}" "${session_id}" "${stop_active}"
}

# Append a `compact_boundary` entry to the transcript jsonl. Real
# Claude Code transcripts emit this line whenever `/compact` (or
# auto-compact) reduces context; the hook re-baselines its counters
# at the *last* such entry. The minimum fields needed for the hook
# predicate are `type` + `subtype`.
append_compact_boundary() {
  local path="$1"
  printf '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}\n' >> "${path}"
}

# ---- defensive paths ----

@test "silent when STRATEGIC_COMPACT_DISABLE=1" {
  local tx
  tx="$(mk_transcript 60 1)"
  STRATEGIC_COMPACT_DISABLE=1 run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}")"
  assert_silent
}

@test "silent when stop_hook_active=true" {
  local tx
  tx="$(mk_transcript 60 1)"
  run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "s1" "true")"
  assert_silent
}

@test "silent when transcript_path missing" {
  run "$(hook remind_strategic_compact.sh)" <<< '{"session_id":"s1","stop_hook_active":false}'
  assert_silent
}

@test "silent when transcript_path unreadable" {
  run "$(hook remind_strategic_compact.sh)" <<< '{"transcript_path":"/nonexistent/path.jsonl","session_id":"s1","stop_hook_active":false}'
  assert_silent
}

@test "silent on non-Stop input shape (no transcript_path key)" {
  run "$(hook remind_strategic_compact.sh)" <<< '{}'
  assert_silent
}

# ---- no signals ----

@test "silent on low tool-count + no PR merge" {
  local tx
  tx="$(mk_transcript 5 0)"
  run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "no-sig-1")"
  assert_silent
}

@test "silent on empty transcript" {
  local tx="${TX_DIR}/empty.jsonl"
  : > "${tx}"
  run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "empty-1")"
  assert_silent
}

# ---- positive signals ----

@test "fires on gh pr merge invocation (even with low tool count)" {
  local tx
  tx="$(mk_transcript 5 1)"
  run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "pr-1")"
  assert_message_contains "Strategic compact suggestion"
  assert_message_contains "gh pr merge invoked"
  assert_message_contains "/compact"
}

@test "fires on tool count >= default threshold (100)" {
  local tx
  tx="$(mk_transcript 105 0)"
  run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "count-1")"
  assert_message_contains "tool-call count 105"
  assert_message_contains "threshold 100"
  assert_message_contains "/compact"
}

@test "silent on tool count below default threshold (99 < 100)" {
  local tx
  tx="$(mk_transcript 99 0)"
  run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "count-2")"
  assert_silent
}

@test "fires on both PR merge AND high tool count (both reasons listed)" {
  local tx
  tx="$(mk_transcript 105 2)"
  run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "both-1")"
  assert_message_contains "gh pr merge invoked 2 time"
  assert_message_contains "tool-call count"
}

# ---- threshold override ----

@test "respects STRATEGIC_COMPACT_TOOL_THRESHOLD override (lower)" {
  local tx
  tx="$(mk_transcript 15 0)"
  STRATEGIC_COMPACT_TOOL_THRESHOLD=10 run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "thresh-1")"
  assert_message_contains "tool-call count 15"
  assert_message_contains "threshold 10"
}

@test "respects STRATEGIC_COMPACT_TOOL_THRESHOLD override (higher)" {
  local tx
  tx="$(mk_transcript 55 0)"
  STRATEGIC_COMPACT_TOOL_THRESHOLD=100 run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "thresh-2")"
  assert_silent
}

@test "ignores non-integer threshold override (falls back to default 100)" {
  local tx
  tx="$(mk_transcript 105 0)"
  STRATEGIC_COMPACT_TOOL_THRESHOLD=garbage run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "thresh-3")"
  assert_message_contains "threshold 100"
}

# ---- throttle (one proposal per signal-set per session) ----

@test "second fire with same signal-set is silent (throttle marker)" {
  local tx
  tx="$(mk_transcript 60 1)"
  run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "throttle-1")"
  assert_message_contains "Strategic compact suggestion"
  # Re-invoke with same session id and same transcript -- should be silent.
  run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "throttle-1")"
  assert_silent
}

@test "different session id re-proposes (no false throttling across sessions)" {
  local tx
  tx="$(mk_transcript 60 1)"
  run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "session-A")"
  assert_message_contains "Strategic compact suggestion"
  run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "session-B")"
  assert_message_contains "Strategic compact suggestion"
}

# ---- only Bash gh pr merge counts (not text mentions) ----

@test "text mention of 'gh pr merge' does NOT count as signal" {
  local tx="${TX_DIR}/text-mention.jsonl"
  printf '{"message":{"role":"assistant","content":[{"type":"text","text":"I will run gh pr merge later"}]}}\n' > "${tx}"
  run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "text-1")"
  assert_silent
}

@test "tool_use of a non-Bash tool with 'gh pr merge' in input does NOT count" {
  local tx="${TX_DIR}/wrong-tool.jsonl"
  printf '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"new_string":"gh pr merge"}}]}}\n' > "${tx}"
  run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "wrong-1")"
  assert_silent
}

# ---- schema regression (Stop hook output shape) ----

@test "fired output omits hookSpecificOutput (Stop schema forbids it)" {
  local tx
  tx="$(mk_transcript 5 1)"
  run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "schema-1")"
  assert_success
  local has_sm has_hso
  has_sm="$(echo "${output}" | jq -r 'has("systemMessage")')"
  has_hso="$(echo "${output}" | jq -r 'has("hookSpecificOutput")')"
  [[ "${has_sm}" == "true" ]] || { echo "expected systemMessage present"; return 1; }
  [[ "${has_hso}" == "false" ]] || { echo "expected hookSpecificOutput absent (Stop schema)"; return 1; }
}

# ---- compact baseline (refs #170) ----

@test "re-baselines tool_count at last compact_boundary (post-compact 0 tools = silent)" {
  local tx
  tx="$(mk_transcript 60 0)"
  append_compact_boundary "${tx}"
  STRATEGIC_COMPACT_TOOL_THRESHOLD=50 run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "compact-tracer-1")"
  assert_silent
}

@test "fires on post-compact tool_count crossing threshold (message uses post-compact count)" {
  local tx
  tx="$(mk_transcript 200 0)"      # huge pre-compact backlog (should be ignored)
  append_compact_boundary "${tx}"
  # Append 55 more tool_use entries AFTER the compact_boundary.
  local i=0
  while (( i < 55 )); do
    printf '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}\n' >> "${tx}"
    i=$((i + 1))
  done
  STRATEGIC_COMPACT_TOOL_THRESHOLD=50 run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "compact-post-1")"
  assert_message_contains "tool-call count 55"
  assert_message_contains "threshold 50"
}

@test "multiple compact_boundary entries: only counts after the LAST one" {
  local tx
  tx="$(mk_transcript 100 0)"
  append_compact_boundary "${tx}"
  # 100 more tools between compact_1 and compact_2.
  local i=0
  while (( i < 100 )); do
    printf '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}\n' >> "${tx}"
    i=$((i + 1))
  done
  append_compact_boundary "${tx}"
  # 30 tools after the LAST compact -> below default 50.
  local j=0
  while (( j < 30 )); do
    printf '{"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}\n' >> "${tx}"
    j=$((j + 1))
  done
  STRATEGIC_COMPACT_TOOL_THRESHOLD=50 run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "compact-multi-1")"
  assert_silent
}

@test "re-baselines pr_merge_count at last compact_boundary" {
  local tx
  tx="$(mk_transcript 0 2)"        # 2 pre-compact PR merges
  append_compact_boundary "${tx}"
  # No tool_use or pr_merge after compact -> both counters should read 0.
  STRATEGIC_COMPACT_TOOL_THRESHOLD=50 run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "compact-pr-1")"
  assert_silent
}

@test "type=user with subtype=compact_boundary does NOT trigger re-baseline" {
  local tx
  tx="$(mk_transcript 60 0)"
  # Decoy entry: same subtype but type=user (not the real compact_boundary
  # marker, which is type=system). Hook should ignore it and count
  # whole-session like the no-compact fallback path.
  printf '{"type":"user","subtype":"compact_boundary","content":"decoy"}\n' >> "${tx}"
  STRATEGIC_COMPACT_TOOL_THRESHOLD=50 run "$(hook remind_strategic_compact.sh)" <<< "$(mk_input "${tx}" "compact-decoy-1")"
  assert_message_contains "tool-call count 60"
}
