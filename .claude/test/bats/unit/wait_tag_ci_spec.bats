#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  GH_STUB_DIR="$(mktemp -d)"
  export PATH="${GH_STUB_DIR}:${PATH}"
  # Isolate $HOME so the script's event-log writes stay inside the
  # tempdir (refs #175 Phase 1).
  HOME_DIR="$(mktemp -d)"
  export HOME="${HOME_DIR}"
}

teardown() {
  rm -rf "${GH_STUB_DIR}" "${HOME_DIR}"
}

# stub_gh <json> — install a `gh` shim that always echoes <json> on stdout
# regardless of arguments. Used to feign `gh run list --json ...` output.
stub_gh() {
  local json="$1"
  printf '#!/usr/bin/env bash\nprintf %%s %q\n' "${json}" > "${GH_STUB_DIR}/gh"
  chmod +x "${GH_STUB_DIR}/gh"
}

@test "--help prints usage and exits 0" {
  run "$(script wait-tag-ci.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--repo"
  assert_output --partial "--branch"
}

@test "missing --repo exits 2" {
  run "$(script wait-tag-ci.sh)" --branch v0.12.2
  assert_failure 2
  assert_output --partial "--repo"
}

@test "missing --branch exits 2" {
  run "$(script wait-tag-ci.sh)" --repo a/b
  assert_failure 2
  assert_output --partial "--branch"
}

@test "unknown arg exits 2" {
  run "$(script wait-tag-ci.sh)" --bogus
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
}

@test "all runs completed + success exits 0 with ALL_DONE" {
  stub_gh '[{"databaseId":1,"name":"release","status":"completed","conclusion":"success"},{"databaseId":2,"name":"build","status":"completed","conclusion":"success"}]'
  run "$(script wait-tag-ci.sh)" --repo a/b --branch v0.12.2 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "release: completed/success"
  assert_output --partial "build: completed/success"
  assert_output --partial "ALL_DONE"
}

@test "mixed success+skipped runs hit ALL_DONE" {
  # refs ycpss91255-docker/docker_harness#86 -- gh run list returns lowercase
  # conclusions; treat skipped as success-equivalent for parity with the
  # PR-scoped wait-pr-ci.sh / wait-pr-ci-batch.sh siblings.
  stub_gh '[{"databaseId":1,"name":"release","status":"completed","conclusion":"success"},{"databaseId":2,"name":"build","status":"completed","conclusion":"skipped"}]'
  run "$(script wait-tag-ci.sh)" --repo a/b --branch v0.12.2 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "build: completed/skipped"
  assert_output --partial "ALL_DONE"
}

@test "any completed run with conclusion != success exits 1 with FAIL <name>" {
  stub_gh '[{"databaseId":1,"name":"release","status":"completed","conclusion":"success"},{"databaseId":2,"name":"build","status":"completed","conclusion":"failure"}]'
  run "$(script wait-tag-ci.sh)" --repo a/b --branch v0.12.2 --interval 0 --max-iterations 3
  assert_failure 1
  assert_output --partial "build: completed/failure"
  assert_output --partial "FAIL build"
}

@test "any in_progress run keeps polling and hits max-iterations 124" {
  stub_gh '[{"databaseId":1,"name":"release","status":"in_progress","conclusion":null},{"databaseId":2,"name":"build","status":"completed","conclusion":"success"}]'
  run "$(script wait-tag-ci.sh)" --repo a/b --branch v0.12.2 --interval 0 --max-iterations 2
  assert_equal "${status}" 124
  assert_output --partial "release: in_progress/?"
  assert_output --partial "max-iterations"
}

@test "empty run list (tag just pushed) keeps polling and hits max-iterations 124" {
  stub_gh '[]'
  run "$(script wait-tag-ci.sh)" --repo a/b --branch v0.12.2 --interval 0 --max-iterations 2
  assert_equal "${status}" 124
  refute_output --partial "ALL_DONE"
  assert_output --partial "max-iterations"
}

@test "custom --check-filter narrows to a specific run name" {
  # Two runs, one matches --check-filter '.name=="release"', the other doesn't.
  # The matched one is success → ALL_DONE despite the unmatched 'build' being in_progress.
  stub_gh '[{"databaseId":1,"name":"release","status":"completed","conclusion":"success"},{"databaseId":2,"name":"build","status":"in_progress","conclusion":null}]'
  run "$(script wait-tag-ci.sh)" --repo a/b --branch v0.12.2 --interval 0 --max-iterations 3 \
    --check-filter '.name=="release"'
  assert_success
  assert_output --partial "release:"
  refute_output --partial "build:"
  assert_output --partial "ALL_DONE"
}

@test "cancelled conclusion counts as failure" {
  stub_gh '[{"databaseId":1,"name":"release","status":"completed","conclusion":"cancelled"}]'
  run "$(script wait-tag-ci.sh)" --repo a/b --branch v0.12.2 --interval 0 --max-iterations 3
  assert_failure 1
  assert_output --partial "FAIL release"
}

# ---- event-log emit (refs #175 Phase 1) ----
#
# Same log file as wait-pr-ci.sh / wait-pr-ci-batch.sh
# (~/.claude/log/wait-pr-ci-events.log). Schema differs: tag CI tracks
# `branch` (the tag / branch name) instead of `prs` or `pairs`. No
# `head_moves` because the tag script does not poll headRefOid.

@test "ALL_DONE tag appends one JSON event line with branch field" {
  stub_gh '[{"databaseId":1,"name":"release","status":"completed","conclusion":"success"}]'
  run "$(script wait-tag-ci.sh)" --repo a/b --branch v0.12.2 --interval 0 --max-iterations 3
  assert_success
  local log="${HOME}/.claude/log/wait-pr-ci-events.log"
  [[ -f "${log}" ]] || { echo "log not at ${log}"; return 1; }
  local lines
  lines="$(wc -l < "${log}")"
  [[ "${lines}" == "1" ]] || { cat "${log}"; return 1; }
  jq -e '
    .script == "wait-tag-ci.sh"
    and .repo == "a/b"
    and .branch == "v0.12.2"
    and .exit_reason == "ALL_DONE"
    and (.iterations | type) == "number"
    and (.elapsed_sec | type) == "number"
    and (.ts | type) == "string"
  ' "${log}" >/dev/null \
    || { echo "schema mismatch:"; cat "${log}"; return 1; }
}

@test "FAIL tag appends event line with exit_reason=FAIL" {
  stub_gh '[{"databaseId":1,"name":"release","status":"completed","conclusion":"failure"}]'
  run "$(script wait-tag-ci.sh)" --repo a/b --branch v0.12.2 --interval 0 --max-iterations 3
  assert_failure 1
  local log="${HOME}/.claude/log/wait-pr-ci-events.log"
  [[ -f "${log}" ]] || { echo "log not at ${log}"; return 1; }
  jq -e '.exit_reason == "FAIL" and .branch == "v0.12.2"' "${log}" >/dev/null \
    || { cat "${log}"; return 1; }
}

@test "max-iterations tag appends event line with exit_reason=timeout_max_iter" {
  stub_gh '[{"databaseId":1,"name":"release","status":"in_progress","conclusion":null}]'
  run "$(script wait-tag-ci.sh)" --repo a/b --branch v0.12.2 --interval 0 --max-iterations 2
  assert_equal "${status}" 124
  local log="${HOME}/.claude/log/wait-pr-ci-events.log"
  [[ -f "${log}" ]] || { echo "log not at ${log}"; return 1; }
  jq -e '.exit_reason == "timeout_max_iter" and .iterations == 2' "${log}" >/dev/null \
    || { cat "${log}"; return 1; }
}
