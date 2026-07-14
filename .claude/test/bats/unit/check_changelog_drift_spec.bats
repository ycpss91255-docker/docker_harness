#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  REPO="$(mktemp_repo changelog)"
}

teardown() {
  rm -rf "${REPO}"
}

@test "fires when code staged without CHANGELOG" {
  ( cd "${REPO}" && echo "echo bye" > script/foo.sh && git add script/foo.sh )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"git commit -m foo\"},\"cwd\":\"${REPO}\"}"
  assert_message_contains "CHANGELOG drift"
}

@test "silent when code AND CHANGELOG staged together" {
  ( cd "${REPO}" && echo "echo bye" > script/foo.sh && echo "## [Unreleased]" >> doc/changelog/CHANGELOG.md && git add script/foo.sh doc/changelog/CHANGELOG.md )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"git commit -m foo\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent when only docs staged" {
  ( cd "${REPO}" && echo "doc only" > NOTE.md && git add NOTE.md )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"git commit -m foo\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent on --amend" {
  ( cd "${REPO}" && echo "echo bye" > script/foo.sh && git add script/foo.sh )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"git commit --amend --no-edit\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent in repo without doc/changelog/CHANGELOG.md (rule N/A)" {
  local repo
  repo="$(mktemp_repo)"
  ( cd "${repo}" && echo "echo bye" > script/foo.sh && git add script/foo.sh )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"git commit -m foo\"},\"cwd\":\"${repo}\"}"
  assert_silent
  rm -rf "${repo}"
}

@test "resolves repo via cd subdir && git commit" {
  ( cd "${REPO}" && echo "echo bye" > script/foo.sh && git add script/foo.sh )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"cd ${REPO} && git commit -m foo\"},\"cwd\":\"/tmp\"}"
  assert_message_contains "CHANGELOG drift"
}
