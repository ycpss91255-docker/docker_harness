#!/usr/bin/env bats

load '../lib/test_helper'

# Stop hook: reads transcript_path JSONL. Fires when ANY task-boundary
# signal holds (gh pr merge invoked, OR tool-call count >= threshold)
# AND the session has NOT already mentioned an optimisation candidate.

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

# Emit an assistant tool_use line.
# emit_tool_use <tool_name> <input_json>
emit_tool_use() {
  local name="$1" input_json="$2"
  jq -nc --arg n "${name}" --argjson i "${input_json}" '{
    message: {
      role: "assistant",
      content: [{ type: "tool_use", name: $n, input: $i }]
    }
  }' >> "${TRANSCRIPT}"
}

# Emit N assistant tool_use lines for an Edit on the same file -- used
# to bump tool-call count past a threshold quickly.
emit_n_edits() {
  local n="$1"
  local i=0
  while (( i < n )); do
    jq -nc '{
      message: {
        role: "assistant",
        content: [{ type: "tool_use", name: "Edit", input: { file_path: "/work/x" } }]
      }
    }' >> "${TRANSCRIPT}"
    i=$((i + 1))
  done
}

# run_hook -- send Stop event JSON to the hook with our transcript.
run_hook() {
  local stop_active="${1:-false}"
  local input
  input="$(jq -nc --arg t "${TRANSCRIPT}" --arg s sess124 --argjson sa "${stop_active}" '{
    transcript_path: $t,
    session_id: $s,
    stop_hook_active: $sa
  }')"
  run "$(hook remind_proactive_optimization.sh)" <<< "${input}"
}

@test "silent on empty transcript" {
  run_hook
  assert_silent
}

@test "silent when no boundary signal (low tool count, no gh pr merge)" {
  emit_text user "Tweak the README."
  emit_text assistant "Done."
  run_hook
  assert_silent
}

@test "fires after gh pr merge invocation with no prior optimisation mention" {
  emit_tool_use Bash '{"command":"gh pr merge 139 -R ycpss91255-docker/docker_harness --squash --delete-branch"}'
  emit_text assistant "PR #139 merged."
  run_hook
  assert_success
  assert_output --partial "Proactive-optimisation reminder"
  assert_output --partial "gh pr merge invoked 1 time(s)"
}

@test "silent when session already raised an optimisation candidate" {
  emit_tool_use Bash '{"command":"gh pr merge 139 -R ycpss91255-docker/docker_harness --squash --delete-branch"}'
  emit_text assistant "PR #139 merged. Noticed the close-issue+comment loop ran 3 times this session -- propose a follow-up to skillify it as a script."
  run_hook
  assert_silent
}

@test "silent when PROACTIVE_OPTIMIZATION_REMIND_DISABLE=1" {
  emit_tool_use Bash '{"command":"gh pr merge 139 -R ycpss91255-docker/docker_harness --squash --delete-branch"}'
  PROACTIVE_OPTIMIZATION_REMIND_DISABLE=1 run_hook
  assert_silent
}

@test "silent when stop_hook_active=true (re-entry guard)" {
  emit_tool_use Bash '{"command":"gh pr merge 139 -R ycpss91255-docker/docker_harness --squash --delete-branch"}'
  run_hook true
  assert_silent
}

@test "fires when tool-count crosses default threshold without gh pr merge" {
  emit_n_edits 50
  run_hook
  assert_success
  assert_output --partial "Proactive-optimisation reminder"
  assert_output --partial "tool-call count 50 >= threshold 50"
}

@test "silent when tool-count below default threshold" {
  emit_n_edits 49
  run_hook
  assert_silent
}

@test "custom threshold via PROACTIVE_OPTIMIZATION_REMIND_THRESHOLD" {
  emit_n_edits 10
  PROACTIVE_OPTIMIZATION_REMIND_THRESHOLD=10 run_hook
  assert_success
  assert_output --partial "Proactive-optimisation reminder"
  assert_output --partial "tool-call count 10 >= threshold 10"
}

@test "throttle: second fire with same signal-set is silent" {
  emit_tool_use Bash '{"command":"gh pr merge 139 -R ycpss91255-docker/docker_harness --squash --delete-branch"}'
  run_hook
  assert_output --partial "Proactive-optimisation reminder"
  run_hook
  assert_silent
}

@test "optimisation mention regex is case-insensitive" {
  emit_tool_use Bash '{"command":"gh pr merge 139 -R ycpss91255-docker/docker_harness --squash --delete-branch"}'
  emit_text assistant "Done. We should AUTOMATE this batch."
  run_hook
  assert_silent
}

@test "silent on missing transcript_path" {
  local input
  input='{"session_id":"sess124","stop_hook_active":false}'
  run "$(hook remind_proactive_optimization.sh)" <<< "${input}"
  assert_silent
}

@test "skill-ify (with hyphen) suppresses the reminder" {
  emit_tool_use Bash '{"command":"gh pr merge 200 -R ycpss91255-docker/docker_harness --squash --delete-branch"}'
  emit_text user "Should we skill-ify that loop?"
  run_hook
  assert_silent
}
