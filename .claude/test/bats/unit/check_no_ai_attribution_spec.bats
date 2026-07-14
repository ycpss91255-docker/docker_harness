#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMPDIR}"
}

@test "fires on Co-Authored-By: Claude" {
  cat > "${TMPDIR}/msg.txt" <<'EOF'
feat: foo

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
  run "$(hook check_no_ai_attribution.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/msg.txt\"}}"
  assert_message_contains "AI attribution marker"
}

@test "fires on Generated with [Claude Code]" {
  echo "Generated with [Claude Code]" > "${TMPDIR}/pr.md"
  run "$(hook check_no_ai_attribution.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/pr.md\"}}"
  assert_message_contains "AI attribution marker"
}

@test "fires on Generated with Claude Code (no brackets)" {
  echo "Generated with Claude Code" > "${TMPDIR}/pr.md"
  run "$(hook check_no_ai_attribution.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/pr.md\"}}"
  assert_message_contains "AI attribution marker"
}

@test "silent on clean file" {
  echo "feat: foo" > "${TMPDIR}/msg.txt"
  run "$(hook check_no_ai_attribution.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/msg.txt\"}}"
  assert_silent
}
