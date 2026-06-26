#!/usr/bin/env bats
#
# Integration: same tool input drives multiple hooks. The hook event
# pipeline runs each registered hook with the same JSON; a misbehaving
# hook can shadow another's signal. Assert each fires (or stays silent)
# independently against shared scenarios.

load '../lib/test_helper'

setup() {
  REPO="$(mktemp_repo changelog)"
}

teardown() {
  rm -rf "${REPO}"
}

@test "git commit with Co-Authored-By: Claude AND code-only stage fires both pre-tool hooks" {
  ( cd "${REPO}" && echo "echo bye" > script/foo.sh && git add script/foo.sh )
  local input
  input="{\"tool_input\":{\"command\":\"git commit -m \\\"feat: x\\n\\nCo-Authored-By: Claude <a@b>\\\"\"},\"cwd\":\"${REPO}\"}"

  run "$(hook remind_no_ai_attribution.sh)" <<< "${input}"
  assert_message_contains "AI 歸屬標記"

  run "$(hook check_changelog_drift.sh)" <<< "${input}"
  assert_message_contains "CHANGELOG drift"
}

@test "gh pr create with attribution body fires both pre-tool hooks" {
  local input='{"tool_input":{"command":"gh pr create --title foo --body \"summary\\n\\nGenerated with [Claude Code]\""}}'

  run "$(hook remind_ci_auto_merge.sh)" <<< "${input}"
  assert_message_contains "auto-merge-on-green"

  run "$(hook remind_no_ai_attribution.sh)" <<< "${input}"
  assert_message_contains "AI 歸屬標記"
}

@test "editing a Dockerfile fires only the TDD reminder, not content-scan hooks" {
  local f="${REPO}/Dockerfile"
  echo "FROM alpine" > "${f}"
  local input="{\"tool_input\":{\"file_path\":\"${f}\"}}"

  run "$(hook remind_tdd_categories.sh)" <<< "${input}"
  assert_message_contains "Dockerfile"

  run "$(hook check_no_emoji.sh)" <<< "${input}"
  assert_silent

  run "$(hook check_no_ai_attribution.sh)" <<< "${input}"
  assert_silent

  run "$(hook check_no_coverage_excl.sh)" <<< "${input}"
  assert_silent
}

