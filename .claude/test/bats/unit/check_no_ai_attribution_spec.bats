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

# --- the changelog directory is one category, not one filename (refs #308) ---
#
# The exemption exists because changelog prose legitimately quotes the strings
# this hook forbids -- an entry describing the rule, or the commit trailer it
# bans. `ycpss91255-docker/base`#926 moved that prose out of
# `doc/changelog/CHANGELOG.md` and into `doc/changelog/vX.Y.md`, leaving the
# exemption pointed at the generated index (which contains nothing but derived
# rows and never needed it) and withheld from the files that do.

@test "silent on a changelog series file (prose that quotes the rule)" {
  mkdir -p "${TMPDIR}/repo/doc/changelog"
  printf -- '- forbid Co-Authored-By: Claude in commit messages\n' \
    > "${TMPDIR}/repo/doc/changelog/v0.43.md"
  run "$(hook check_no_ai_attribution.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/repo/doc/changelog/v0.43.md\"}}"
  assert_silent
}

@test "silent on the generated changelog index" {
  mkdir -p "${TMPDIR}/repo/doc/changelog"
  printf -- '- Co-Authored-By: Claude\n' > "${TMPDIR}/repo/doc/changelog/CHANGELOG.md"
  run "$(hook check_no_ai_attribution.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/repo/doc/changelog/CHANGELOG.md\"}}"
  assert_silent
}
