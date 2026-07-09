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
