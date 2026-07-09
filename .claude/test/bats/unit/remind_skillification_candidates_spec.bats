#!/usr/bin/env bats

load '../lib/test_helper'

# Stop hook: reads transcript_path JSONL. Fires when an auto-detectable
# skillification signal crosses its threshold (/tmp/*.sh re-use OR
# parser-fallback pattern repetition) AND no skillification candidate
# was already raised in the conversation.

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

# emit_bash <command-string>
emit_bash() {
  local cmd="$1"
  jq -nc --arg c "${cmd}" '{
    message: {
      role: "assistant",
      content: [{ type: "tool_use", name: "Bash", input: { command: $c } }]
    }
  }' >> "${TRANSCRIPT}"
}

# emit_bash_n <N> <cmd-prefix> -- emit N Bash tool uses with cmd-prefix-<i>.
emit_bash_n() {
  local n="$1" prefix="$2"
  local i=0
  while (( i < n )); do
    emit_bash "${prefix} ${i}"
    i=$((i + 1))
  done
}

# run_hook -- send Stop event JSON to the hook with our transcript.
run_hook() {
  local stop_active="${1:-false}"
  local input
  input="$(jq -nc --arg t "${TRANSCRIPT}" --arg s sess125 --argjson sa "${stop_active}" '{
    transcript_path: $t,
    session_id: $s,
    stop_hook_active: $sa
  }')"
  run "$(hook remind_skillification_candidates.sh)" <<< "${input}"
}

@test "silent on empty transcript" {
  run_hook
  assert_silent
}

@test "silent when no /tmp/*.sh and no parser-fallback patterns" {
  emit_bash "git status"
  emit_bash "ls -la"
  emit_text assistant "Done."
  run_hook
  assert_silent
}

@test "silent with 2 /tmp/*.sh invocations (below default threshold 3)" {
  emit_bash "bash /tmp/foo.sh --arg a"
  emit_bash "bash /tmp/foo.sh --arg b"
  run_hook
  assert_silent
}

@test "fires after 3 /tmp/*.sh invocations" {
  emit_bash "bash /tmp/foo.sh --arg a"
  emit_bash "bash /tmp/foo.sh --arg b"
  emit_bash "bash /tmp/foo.sh --arg c"
  run_hook
  assert_success
  assert_output --partial "Skillification reminder"
  assert_output --partial "/tmp/*.sh invocations 3 >= threshold 3"
}

@test "fires after 3 parser-fallback heredoc-redirect patterns" {
  emit_bash "cat <<EOF > /tmp/x.txt
hello
EOF"
  emit_bash "cat <<EOF > /tmp/y.txt
world
EOF"
  emit_bash "cat <<EOF > /tmp/z.txt
again
EOF"
  run_hook
  assert_success
  assert_output --partial "Skillification reminder"
  assert_output --partial "parser-fallback pattern hits 3 >= threshold 3"
}

@test "fires after 3 cd-path-and-tool patterns" {
  emit_bash "cd /work/a && git fetch"
  emit_bash "cd /work/b && git fetch"
  emit_bash "cd /work/c && git fetch"
  run_hook
  assert_success
  assert_output --partial "Skillification reminder"
}

@test "silent when session already raised a skillification candidate" {
  emit_bash "bash /tmp/foo.sh a"
  emit_bash "bash /tmp/foo.sh b"
  emit_bash "bash /tmp/foo.sh c"
  emit_text assistant "Candidate: promote /tmp/foo.sh to .claude/scripts/foo.sh as a follow-up."
  run_hook
  assert_silent
}

@test "silent when SKILLIFICATION_REMIND_DISABLE=1" {
  emit_bash "bash /tmp/foo.sh a"
  emit_bash "bash /tmp/foo.sh b"
  emit_bash "bash /tmp/foo.sh c"
  SKILLIFICATION_REMIND_DISABLE=1 run_hook
  assert_silent
}

@test "silent when stop_hook_active=true (re-entry guard)" {
  emit_bash "bash /tmp/foo.sh a"
  emit_bash "bash /tmp/foo.sh b"
  emit_bash "bash /tmp/foo.sh c"
  run_hook true
  assert_silent
}

@test "custom SKILLIFICATION_TMP_THRESHOLD lowers the bar" {
  emit_bash "bash /tmp/foo.sh a"
  emit_bash "bash /tmp/foo.sh b"
  SKILLIFICATION_TMP_THRESHOLD=2 run_hook
  assert_success
  assert_output --partial "/tmp/*.sh invocations 2 >= threshold 2"
}

@test "custom SKILLIFICATION_PARSER_THRESHOLD lowers the bar" {
  emit_bash "cd /a && git fetch"
  emit_bash "cd /b && git fetch"
  SKILLIFICATION_PARSER_THRESHOLD=2 run_hook
  assert_success
  assert_output --partial "parser-fallback pattern hits 2 >= threshold 2"
}

@test "throttle: second fire with same signal-set is silent" {
  emit_bash_n 3 "bash /tmp/foo.sh"
  run_hook
  assert_output --partial "Skillification reminder"
  run_hook
  assert_silent
}

@test "mention-regex case-insensitive (SKILL-IFY uppercase)" {
  emit_bash_n 3 "bash /tmp/foo.sh"
  emit_text user "Should we SKILL-IFY this loop?"
  run_hook
  assert_silent
}

@test "silent on missing transcript_path" {
  local input
  input='{"session_id":"sess125","stop_hook_active":false}'
  run "$(hook remind_skillification_candidates.sh)" <<< "${input}"
  assert_silent
}

@test "non-/tmp .sh invocation does NOT count toward /tmp threshold" {
  emit_bash "bash /opt/foo.sh"
  emit_bash "bash /opt/foo.sh"
  emit_bash "bash /opt/foo.sh"
  run_hook
  assert_silent
}

@test "fires when BOTH signals cross threshold (reason lists both)" {
  emit_bash_n 3 "bash /tmp/foo.sh"
  emit_bash "cd /a && git fetch"
  emit_bash "cd /b && git fetch"
  emit_bash "cd /c && git fetch"
  run_hook
  assert_success
  assert_output --partial "/tmp/*.sh invocations 3"
  assert_output --partial "parser-fallback pattern hits 3"
}
