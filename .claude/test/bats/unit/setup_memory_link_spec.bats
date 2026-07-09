#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  TEST_HOME="$(mktemp -d)"
  export TEST_HOME
  WS="$(mktemp -d)"
  export WS
  mkdir -p "${WS}/.claude/memory"
  printf 'index\n' > "${WS}/.claude/memory/MEMORY.md"
  printf 'entry-a\n' > "${WS}/.claude/memory/feedback_a.md"
}

teardown() {
  rm -rf "${TEST_HOME}" "${WS}"
}

# Compute the encoded project subdir for assertions.
encoded() {
  local p="${1%/}"
  printf '%s\n' "${p//\//-}"
}

# ---- arg parsing ----

@test "--help prints usage and exits 0" {
  run "$(script setup-memory-link.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--workspace"
  assert_output --partial "--home"
  assert_output --partial "--force"
  assert_output --partial "--dry-run"
}

@test "unknown arg exits 2" {
  run "$(script setup-memory-link.sh)" --bogus
  assert_failure 2
  assert_output --partial "unknown arg"
}

@test "missing workspace memory dir exits 2" {
  rm -rf "${WS}/.claude/memory"
  run "$(script setup-memory-link.sh)" --workspace "${WS}" --home "${TEST_HOME}"
  assert_failure 2
  assert_output --partial "repo memory not found"
}

@test "non-existent workspace exits 2" {
  run "$(script setup-memory-link.sh)" --workspace "/nonexistent/path" --home "${TEST_HOME}"
  assert_failure 2
  assert_output --partial "workspace not a directory"
}

# ---- happy path ----

@test "creates symlink when project dir does not yet exist" {
  run "$(script setup-memory-link.sh)" --workspace "${WS}" --home "${TEST_HOME}"
  assert_success
  assert_output --partial "OK: created symlink"

  local enc
  enc="$(encoded "${WS}")"
  local link="${TEST_HOME}/.claude/projects/${enc}/memory"
  [[ -L "${link}" ]]
  local target
  target="$(readlink -- "${link}")"
  [[ "${target}" == "${WS}/.claude/memory" ]]
}

@test "creates symlink when project dir exists but memory does not" {
  local enc
  enc="$(encoded "${WS}")"
  mkdir -p "${TEST_HOME}/.claude/projects/${enc}"
  run "$(script setup-memory-link.sh)" --workspace "${WS}" --home "${TEST_HOME}"
  assert_success
  local link="${TEST_HOME}/.claude/projects/${enc}/memory"
  [[ -L "${link}" ]]
}

# ---- idempotency ----

@test "idempotent: existing correct symlink leaves it alone" {
  "$(script setup-memory-link.sh)" --workspace "${WS}" --home "${TEST_HOME}" >/dev/null
  run "$(script setup-memory-link.sh)" --workspace "${WS}" --home "${TEST_HOME}"
  assert_success
  assert_output --partial "OK: symlink already points at"
  assert_output --partial "nothing to do"
}

# ---- wrong-target symlink ----

@test "replaces wrong-target symlink" {
  local enc
  enc="$(encoded "${WS}")"
  mkdir -p "${TEST_HOME}/.claude/projects/${enc}"
  local link="${TEST_HOME}/.claude/projects/${enc}/memory"
  local other
  other="$(mktemp -d)"
  ln -s -- "${other}" "${link}"
  run "$(script setup-memory-link.sh)" --workspace "${WS}" --home "${TEST_HOME}"
  assert_success
  assert_output --partial "symlink target differs"
  assert_output --partial "OK: created symlink"
  local new_target
  new_target="$(readlink -- "${link}")"
  [[ "${new_target}" == "${WS}/.claude/memory" ]]
  rm -rf "${other}"
}

# ---- existing real dir, matching content ----

@test "existing dir matching repo copy is replaced without --force" {
  local enc
  enc="$(encoded "${WS}")"
  local link="${TEST_HOME}/.claude/projects/${enc}/memory"
  mkdir -p "${link}"
  cp -r "${WS}/.claude/memory/." "${link}/"
  run "$(script setup-memory-link.sh)" --workspace "${WS}" --home "${TEST_HOME}"
  assert_success
  assert_output --partial "existing dir matched repo copy"
  [[ -L "${link}" ]]
}

# ---- existing real dir, diverged content ----

@test "existing dir with extra file refuses without --force" {
  local enc
  enc="$(encoded "${WS}")"
  local link="${TEST_HOME}/.claude/projects/${enc}/memory"
  mkdir -p "${link}"
  cp -r "${WS}/.claude/memory/." "${link}/"
  printf 'private\n' > "${link}/feedback_private_only.md"
  run "$(script setup-memory-link.sh)" --workspace "${WS}" --home "${TEST_HOME}"
  assert_failure 1
  assert_output --partial "existing memory dir differs from repo copy"
  assert_output --partial "refuse to replace"
  # Dir untouched
  [[ -d "${link}" && ! -L "${link}" ]]
  [[ -f "${link}/feedback_private_only.md" ]]
}

@test "existing dir with extra file replaced with --force (backup created)" {
  local enc
  enc="$(encoded "${WS}")"
  local link="${TEST_HOME}/.claude/projects/${enc}/memory"
  mkdir -p "${link}"
  cp -r "${WS}/.claude/memory/." "${link}/"
  printf 'private\n' > "${link}/feedback_private_only.md"
  run "$(script setup-memory-link.sh)" --workspace "${WS}" --home "${TEST_HOME}" --force
  assert_success
  assert_output --partial "backed up existing dir to:"
  assert_output --partial "OK: created symlink"
  [[ -L "${link}" ]]
  # Backup exists with the private file.
  run bash -c "ls -d ${TEST_HOME}/.claude/projects/${enc}/memory.backup-* | head -1"
  assert_success
  local backup="${output}"
  [[ -f "${backup}/feedback_private_only.md" ]]
}

# ---- --dry-run ----

@test "--dry-run does not modify anything" {
  run "$(script setup-memory-link.sh)" --workspace "${WS}" --home "${TEST_HOME}" --dry-run
  assert_success
  assert_output --partial "dry-run"
  local enc
  enc="$(encoded "${WS}")"
  local link="${TEST_HOME}/.claude/projects/${enc}/memory"
  [[ ! -e "${link}" ]]
}

# ---- encoding ----

@test "encoded path replaces every / with -" {
  # Workspace with deep path.
  local deep
  deep="$(mktemp -d)/a/b/c"
  mkdir -p "${deep}/.claude/memory"
  printf 'i\n' > "${deep}/.claude/memory/MEMORY.md"
  run "$(script setup-memory-link.sh)" --workspace "${deep}" --home "${TEST_HOME}"
  assert_success
  # Encoded form contains -a-b-c sub-portion
  local enc
  enc="$(encoded "${deep}")"
  [[ -L "${TEST_HOME}/.claude/projects/${enc}/memory" ]]
  rm -rf "$(dirname "$(dirname "$(dirname "${deep}")")")"
}

@test "trailing slash on workspace is normalised" {
  run "$(script setup-memory-link.sh)" --workspace "${WS}/" --home "${TEST_HOME}"
  assert_success
  local enc
  enc="$(encoded "${WS}")"
  [[ -L "${TEST_HOME}/.claude/projects/${enc}/memory" ]]
}
