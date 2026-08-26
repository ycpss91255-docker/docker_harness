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
  assert_message_contains "shell function"
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

# Repo-detection / TDD-capability adaptation (refs #75, #237). Reminder
# lists ONLY the ISTQB levels the repo has infra for (test/bats/<level>/),
# plus static analysis. When the repo has no level dir, fall back to the
# all-levels baseline so the generic guidance (and the tests above) keep
# working. Smoke is a TYPE inside the system clause, not a level.

@test "[#75/#237] .sh in repo with only test/bats/system/ drops Unit + Integration" {
  mkdir -p "${TMPDIR}/repo/test/bats/system"
  echo "FROM x" > "${TMPDIR}/repo/Dockerfile"
  mkdir -p "${TMPDIR}/repo/script"
  echo "echo a" > "${TMPDIR}/repo/script/foo.sh"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/repo/script/foo.sh\"}}"
  assert_message_contains "shell function"
  assert_message_contains "System"
  assert_message_contains "Static"
  refute_output --partial "Unit required"
  refute_output --partial "Add Integration"
}

@test "[#220/#237] .sh in repo detected via root justfile only (no Dockerfile) scopes levels" {
  mkdir -p "${TMPDIR}/jrepo/test/bats/system"
  echo "test:" > "${TMPDIR}/jrepo/justfile"
  mkdir -p "${TMPDIR}/jrepo/script"
  echo "echo a" > "${TMPDIR}/jrepo/script/foo.sh"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/jrepo/script/foo.sh\"}}"
  assert_message_contains "System"
  refute_output --partial "Unit required"
  refute_output --partial "Add Integration"
}

@test "[#280] retired CI runner files are not repo-root markers" {
  # justfile.ci / Makefile.ci were the make->just transition runners; no
  # repo root ships either any more. A stray one in a subdirectory must
  # not shadow the real repo root, or level scoping is lost.
  local runner
  for runner in justfile.ci Makefile.ci; do
    local repo="${TMPDIR}/${runner}-repo"
    mkdir -p "${repo}/test/bats/system" "${repo}/legacy"
    echo "test:" > "${repo}/justfile"
    echo "upgrade:" > "${repo}/legacy/${runner}"
    echo "echo a" > "${repo}/legacy/foo.sh"
    run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/legacy/foo.sh\"}}"
    assert_message_contains "System"
    refute_output --partial "Unit required"
  done
}

@test "[#75/#237] .sh in repo with full level infra keeps unit + integration + system" {
  mkdir -p "${TMPDIR}/repo/test/bats/unit" \
           "${TMPDIR}/repo/test/bats/integration" \
           "${TMPDIR}/repo/test/bats/system"
  echo "FROM x" > "${TMPDIR}/repo/Dockerfile"
  mkdir -p "${TMPDIR}/repo/script"
  echo "echo a" > "${TMPDIR}/repo/script/foo.sh"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/repo/script/foo.sh\"}}"
  assert_message_contains "Unit required"
  assert_message_contains "Integration"
  assert_message_contains "System"
  assert_message_contains "Static"
}

@test "[#75/#237] Dockerfile in repo with only test/bats/system/ keeps System (Smoke type) + static" {
  mkdir -p "${TMPDIR}/repo/test/bats/system"
  echo "FROM x" > "${TMPDIR}/repo/Dockerfile"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/repo/Dockerfile\"}}"
  assert_message_contains "Dockerfile"
  assert_message_contains "System"
  assert_message_contains "Smoke type"
  assert_message_contains "Static"
  refute_output --partial "Add Integration"
}

@test "[#75/#237] repo without any test/bats level dir falls back to all levels" {
  mkdir -p "${TMPDIR}/repo/script"
  echo "FROM x" > "${TMPDIR}/repo/Dockerfile"
  echo "echo a" > "${TMPDIR}/repo/script/foo.sh"
  run "$(hook remind_tdd_categories.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/repo/script/foo.sh\"}}"
  assert_message_contains "Unit required"
  assert_message_contains "Integration"
  assert_message_contains "System"
}
