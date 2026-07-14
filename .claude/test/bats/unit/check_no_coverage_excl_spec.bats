#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMPDIR}"
}

@test "fires on LCOV_EXCL_LINE" {
  cat > "${TMPDIR}/x.sh" <<'EOF'
echo a  # LCOV_EXCL_LINE
EOF
  run "$(hook check_no_coverage_excl.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/x.sh\"}}"
  assert_message_contains "coverage-exclusion comment not allowed"
}

@test "fires on LCOV_EXCL_START / STOP block" {
  cat > "${TMPDIR}/x.sh" <<'EOF'
# LCOV_EXCL_START
echo skip
# LCOV_EXCL_STOP
EOF
  run "$(hook check_no_coverage_excl.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/x.sh\"}}"
  assert_message_contains "coverage-exclusion comment not allowed"
}

@test "fires on kcov-excl" {
  cat > "${TMPDIR}/x.sh" <<'EOF'
echo a  # kcov-excl
EOF
  run "$(hook check_no_coverage_excl.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/x.sh\"}}"
  assert_message_contains "coverage-exclusion comment not allowed"
}

@test "silent on clean file" {
  echo "echo ok" > "${TMPDIR}/x.sh"
  run "$(hook check_no_coverage_excl.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/x.sh\"}}"
  assert_silent
}

@test "silent on .md file (skip)" {
  echo "LCOV_EXCL_LINE explained" > "${TMPDIR}/note.md"
  run "$(hook check_no_coverage_excl.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/note.md\"}}"
  assert_silent
}
