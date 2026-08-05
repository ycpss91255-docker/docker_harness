#!/usr/bin/env bats

load '../lib/test_helper'

# auto_allow_touch_ack.sh — PreToolUse Bash hook that programmatically
# allows `touch <TMPDIR-or-/tmp>/claude-checkpoint-*.ack` without falling
# into the catch-all touch ask flow. Companion to the /tmp checkpoint
# protocol (ADR-00000002) consumed by the Tier 2 E2 enforcement hooks.

setup() {
  export TMPDIR="${BATS_TEST_TMPDIR}"
}

# ---- positive: matching ack paths return ALLOW ----

@test "allows touch /tmp/claude-checkpoint-foo.ack" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"tool_input":{"command":"touch /tmp/claude-checkpoint-foo.ack"}}'
  assert_permission_decision "allow"
}

@test "allows touch /tmp/claude-checkpoint-make-upgrade-sess123-abc.ack (slug-session-hash shape)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"tool_input":{"command":"touch /tmp/claude-checkpoint-make-upgrade-sess123-abc.ack"}}'
  assert_permission_decision "allow"
}

@test "allows touch \$TMPDIR/claude-checkpoint-bar.ack (literal \$TMPDIR token)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"tool_input":{"command":"touch $TMPDIR/claude-checkpoint-bar.ack"}}'
  assert_permission_decision "allow"
}

@test "allows touch -- /tmp/claude-checkpoint-baz.ack (after -- separator)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"tool_input":{"command":"touch -- /tmp/claude-checkpoint-baz.ack"}}'
  assert_permission_decision "allow"
}

# ---- negative: non-matching touch commands fall through ----

@test "silent on touch /tmp/other.txt (not a checkpoint ack)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"tool_input":{"command":"touch /tmp/other.txt"}}'
  assert_silent
}

@test "silent on touch /etc/shadow (outside TMPDIR + /tmp)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"tool_input":{"command":"touch /etc/shadow"}}'
  assert_silent
}

@test "silent on touch /tmp/claude-checkpoint-foo.md (.md not .ack)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"tool_input":{"command":"touch /tmp/claude-checkpoint-foo.md"}}'
  assert_silent
}

@test "silent on touch /tmp/claude-checkpoint-.ack (empty slug rejected)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"tool_input":{"command":"touch /tmp/claude-checkpoint-.ack"}}'
  assert_silent
}

@test "silent on non-touch command (ls /tmp/claude-checkpoint-foo.ack)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"tool_input":{"command":"ls /tmp/claude-checkpoint-foo.ack"}}'
  assert_silent
}

# ---- boundary: path traversal + multi-token + chain guards ----

@test "silent on touch /tmp/../etc/claude-checkpoint-x.ack (.. traversal)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"tool_input":{"command":"touch /tmp/../etc/claude-checkpoint-x.ack"}}'
  assert_silent
}

@test "silent on touch /tmp/claude-checkpoint-a.ack && rm -rf / (command chain)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"tool_input":{"command":"touch /tmp/claude-checkpoint-a.ack && rm -rf /"}}'
  assert_silent
}

@test "silent on touch /tmp/claude-checkpoint-a.ack /tmp/other.txt (multi-arg with non-ack)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"tool_input":{"command":"touch /tmp/claude-checkpoint-a.ack /tmp/other.txt"}}'
  assert_silent
}

@test "silent on touch /tmp/CLAUDE-CHECKPOINT-foo.ack (case-sensitive prefix)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"tool_input":{"command":"touch /tmp/CLAUDE-CHECKPOINT-foo.ack"}}'
  assert_silent
}

@test "silent on empty command" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"tool_input":{"command":""}}'
  assert_silent
}

# ---- subagent calls never get the one-click lift (refs #267) ----
#
# The ack exists to capture a HUMAN's intent to lift a Tier 2 E2 gate. An
# autonomous implementer that can write its own ack lifts those gates by
# itself, which defeats them. Hooks do fire for subagent tool calls, and a
# subagent payload carries `agent_id` / `agent_type` that a main-session
# payload does not -- so an agent-originated ack falls through to the normal
# ask flow, where the human answers.

@test "silent on a matching ack when the caller is a subagent (agent_id present)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"agent_id":"ac98fe516","agent_type":"general-purpose","tool_input":{"command":"touch /tmp/claude-checkpoint-foo.ack"}}'
  assert_silent
}

@test "silent on a matching ack when the caller is a subagent (agent_type only)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"agent_type":"Explore","tool_input":{"command":"touch /tmp/claude-checkpoint-foo.ack"}}'
  assert_silent
}

@test "still allows a matching ack when the agent fields are absent (main session)" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"session_id":"a2bc46c6","tool_input":{"command":"touch /tmp/claude-checkpoint-foo.ack"}}'
  assert_permission_decision "allow"
}

@test "still allows a matching ack when the agent fields are present but empty" {
  run "$(hook auto_allow_touch_ack.sh)" <<< '{"agent_id":"","agent_type":"","tool_input":{"command":"touch /tmp/claude-checkpoint-foo.ack"}}'
  assert_permission_decision "allow"
}
