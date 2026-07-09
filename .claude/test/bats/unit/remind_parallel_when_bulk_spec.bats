#!/usr/bin/env bats

load '../lib/test_helper'

# UserPromptSubmit hook: fires when the user prompt has a bulk-work
# indicator (N >= threshold + plural noun, OR all/every + plural noun,
# OR explicit comma list >= threshold) AND the prompt does not already
# mention parallel-Agent dispatch. Throttled once per session per
# matched signal.

setup() {
  MARKER_TMP="$(mktemp -d)"
  export TMPDIR="${MARKER_TMP}"
}

teardown() {
  rm -rf "${MARKER_TMP}"
}

# run_hook <prompt> -- send UserPromptSubmit event JSON to the hook.
run_hook() {
  local prompt="$1"
  local input
  input="$(jq -nc --arg p "${prompt}" --arg s sess126 '{
    session_id: $s,
    hook_event_name: "UserPromptSubmit",
    prompt: $p
  }')"
  run "$(hook remind_parallel_when_bulk.sh)" <<< "${input}"
}

@test "silent on empty prompt" {
  run_hook ""
  assert_silent
}

@test "silent on small N (3 repos, below default threshold 4)" {
  run_hook "Fix 3 repos: A, B, C."
  assert_silent
}

@test "fires on numeric N=11 repos" {
  run_hook "Process 11 repos under ycpss91255-docker."
  assert_success
  assert_output --partial "Parallel-Agent reminder"
  assert_output --partial "numeric N=11"
}

@test "fires on numeric N=4 PRs (boundary inclusive)" {
  run_hook "Open 4 PRs across the active downstreams."
  assert_success
  assert_output --partial "numeric N=4"
}

@test "fires on 'all repos' (quantifier without explicit N)" {
  run_hook "Update all repos with the new template version."
  assert_success
  assert_output --partial "quantifier 'all'"
}

@test "fires on 'every PR'" {
  run_hook "Add the missing label to every PR opened this week."
  assert_success
  assert_output --partial "quantifier 'every'"
}

@test "fires on comma-list of >=4 repo-shaped tokens" {
  run_hook "Upgrade ai_agent, claude_code, codex_cli, gemini_cli to v0.32.0."
  assert_success
  assert_output --partial "comma-list with"
}

@test "silent on comma-list of only 3 tokens" {
  run_hook "Upgrade ai_agent, claude_code, codex_cli to v0.32.0."
  assert_silent
}

@test "silent when prompt already mentions parallel" {
  run_hook "Process 11 repos in parallel using 3 Agents."
  assert_silent
}

@test "silent when prompt mentions 'subagent'" {
  run_hook "Spawn 4 subagents to update all repos."
  assert_silent
}

@test "silent on PARALLEL_REMIND_DISABLE=1" {
  PARALLEL_REMIND_DISABLE=1 run_hook "Process 11 repos."
  assert_silent
}

@test "custom PARALLEL_REMIND_THRESHOLD raises the bar" {
  PARALLEL_REMIND_THRESHOLD=10 run_hook "Process 5 repos."
  assert_silent
}

@test "custom PARALLEL_REMIND_THRESHOLD also affects comma-list" {
  PARALLEL_REMIND_THRESHOLD=6 run_hook "Upgrade ai_agent, claude_code, codex_cli, gemini_cli, ros1_bridge."
  assert_silent
}

@test "throttle: same signal fires once per session" {
  run_hook "Process 11 repos."
  assert_output --partial "Parallel-Agent reminder"
  run_hook "Process 11 repos."
  assert_silent
}

@test "case-insensitive: 'ALL REPOS' fires" {
  run_hook "Upgrade ALL REPOS to the new tag."
  assert_success
  assert_output --partial "Parallel-Agent reminder"
}

@test "ordinal numbers do NOT trigger (the 4th issue)" {
  run_hook "Look at the 4th issue in the backlog."
  assert_silent
}

@test "version-shaped numbers do NOT trigger (v0.32.0)" {
  run_hook "Upgrade base to v0.32.0."
  assert_silent
}

@test "CJK quantifier '所有 repo' fires" {
  run_hook "處理所有 repos under ycpss91255-docker."
  assert_success
  assert_output --partial "Parallel-Agent reminder"
}
