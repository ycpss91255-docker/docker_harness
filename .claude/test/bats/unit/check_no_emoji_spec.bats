#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMPDIR}"
}

@test "fires when file contains emoji" {
  printf 'hello \xF0\x9F\x9A\x80 world\n' > "${TMPDIR}/x.txt"
  run "$(hook check_no_emoji.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/x.txt\"}}"
  assert_message_contains "Emoji detected"
}

@test "silent on clean ASCII file" {
  echo "hello world" > "${TMPDIR}/x.txt"
  run "$(hook check_no_emoji.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/x.txt\"}}"
  assert_silent
}

@test "silent when file does not exist" {
  run "$(hook check_no_emoji.sh)" <<< '{"tool_input":{"file_path":"/no/such/path"}}'
  assert_silent
}

@test "silent when file is binary" {
  printf '\x00\x01\x02\x03' > "${TMPDIR}/bin"
  run "$(hook check_no_emoji.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/bin\"}}"
  assert_silent
}

@test "silent on meta-doc CLAUDE.md (legitimate emoji quoting)" {
  mkdir -p "${TMPDIR}/repo"
  printf 'rule: do not use emoji like \xF0\x9F\x9A\x80\n' > "${TMPDIR}/repo/CLAUDE.md"
  run "$(hook check_no_emoji.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/repo/CLAUDE.md\"}}"
  assert_silent
}

@test "silent on .claude/commands/*.md meta-doc (rule description)" {
  mkdir -p "${TMPDIR}/repo/.claude/commands"
  printf 'detect this: \xF0\x9F\x9A\x80\n' > "${TMPDIR}/repo/.claude/commands/foo.md"
  run "$(hook check_no_emoji.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/repo/.claude/commands/foo.md\"}}"
  assert_silent
}
