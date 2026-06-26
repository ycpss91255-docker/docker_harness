#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMPDIR}"
}

@test "fires on .sh file edit" {
  echo "echo a" > "${TMPDIR}/foo.sh"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/foo.sh\"}}"
  assert_message_contains "shell 函式"
}

@test "fires on Dockerfile edit" {
  echo "FROM alpine" > "${TMPDIR}/Dockerfile"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/Dockerfile\"}}"
  assert_message_contains "Dockerfile"
}

@test "fires on compose.yaml edit" {
  echo "services:" > "${TMPDIR}/compose.yaml"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/compose.yaml\"}}"
  assert_message_contains "compose"
}

@test "fires on entrypoint.sh edit" {
  echo "#!/bin/sh" > "${TMPDIR}/entrypoint.sh"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/entrypoint.sh\"}}"
  assert_message_contains "entrypoint"
}

@test "fires on .hadolint.yaml edit" {
  echo "ignored:" > "${TMPDIR}/.hadolint.yaml"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/.hadolint.yaml\"}}"
  assert_message_contains "lint"
}

@test "silent on .md edit" {
  echo "# title" > "${TMPDIR}/README.md"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/README.md\"}}"
  assert_silent
}

@test "silent on .bats edit" {
  echo "@test x { :; }" > "${TMPDIR}/foo.bats"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/foo.bats\"}}"
  assert_silent
}

@test "silent on .claude/ internals" {
  mkdir -p "${TMPDIR}/.claude/hooks"
  echo "echo a" > "${TMPDIR}/.claude/hooks/foo.sh"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/.claude/hooks/foo.sh\"}}"
  assert_silent
}

# Repo-detection / TDD-capability adaptation (refs #75). Reminder
# should list ONLY the test categories the repo actually has infra for,
# rather than the legacy generic 4-category claim. When the repo has
# no test/<cat>/ at all, fall back to the 4-category baseline so the
# pre-#75 behaviour (and existing tests above) keep working.

@test "[#75] .sh in downstream repo with only test/smoke/ drops Unit + Integration" {
  mkdir -p "${TMPDIR}/repo/test/smoke"
  echo "FROM x" > "${TMPDIR}/repo/Dockerfile"
  mkdir -p "${TMPDIR}/repo/script"
  echo "echo a" > "${TMPDIR}/repo/script/foo.sh"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/repo/script/foo.sh\"}}"
  assert_message_contains "shell 函式"
  assert_message_contains "Smoke"
  assert_message_contains "Lint"
  refute_output --partial "Unit 必須"
  refute_output --partial "Integration 必須"
}

@test "[#220] .sh in repo detected via root justfile only (no Dockerfile) scopes categories" {
  mkdir -p "${TMPDIR}/jrepo/test/smoke"
  echo "test:" > "${TMPDIR}/jrepo/justfile"
  mkdir -p "${TMPDIR}/jrepo/script"
  echo "echo a" > "${TMPDIR}/jrepo/script/foo.sh"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/jrepo/script/foo.sh\"}}"
  assert_message_contains "Smoke"
  refute_output --partial "Unit 必須"
  refute_output --partial "Integration 必須"
}

@test "[#75] .sh in repo with full test infra keeps all 4 categories" {
  mkdir -p "${TMPDIR}/repo/test/smoke" \
           "${TMPDIR}/repo/test/unit" \
           "${TMPDIR}/repo/test/integration"
  echo "FROM x" > "${TMPDIR}/repo/Dockerfile"
  mkdir -p "${TMPDIR}/repo/script"
  echo "echo a" > "${TMPDIR}/repo/script/foo.sh"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/repo/script/foo.sh\"}}"
  assert_message_contains "Unit 必須"
  assert_message_contains "Smoke"
  assert_message_contains "Integration"
  assert_message_contains "Lint"
}

@test "[#75] Dockerfile in repo with only test/smoke/ keeps Smoke + Lint" {
  mkdir -p "${TMPDIR}/repo/test/smoke"
  echo "FROM x" > "${TMPDIR}/repo/Dockerfile"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/repo/Dockerfile\"}}"
  assert_message_contains "Dockerfile"
  assert_message_contains "Smoke"
  assert_message_contains "Lint"
  refute_output --partial "Integration 必須"
}

@test "[#75] repo without any test/ subdir falls back to all 4 categories" {
  mkdir -p "${TMPDIR}/repo/script"
  echo "FROM x" > "${TMPDIR}/repo/Dockerfile"
  echo "echo a" > "${TMPDIR}/repo/script/foo.sh"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/repo/script/foo.sh\"}}"
  assert_message_contains "Unit 必須"
  assert_message_contains "Integration"
}
