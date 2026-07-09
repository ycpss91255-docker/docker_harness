#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  REPO_DIR="$(mktemp -d)"
  export REPO_DIR
  mkdir -p "${REPO_DIR}/.claude/scripts"
}

teardown() {
  rm -rf "${REPO_DIR}"
}

@test "--help prints usage and exits 0" {
  run "$(script check-log-helper-usage.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "log-allow:script"
}

@test "unknown arg exits 2" {
  run "$(script check-log-helper-usage.sh)" --bogus
  assert_failure 2
  assert_output --partial "unknown arg"
}

@test "non-existent scripts dir exits 2" {
  run "$(script check-log-helper-usage.sh)" --scripts-dir "${REPO_DIR}/nonexistent"
  assert_failure 2
  assert_output --partial "scripts dir not found"
}

@test "empty scripts dir passes" {
  run "$(script check-log-helper-usage.sh)" --scripts-dir "${REPO_DIR}/.claude/scripts"
  assert_success
  assert_output --partial "clean"
  assert_output --partial "0 script"
}

@test "script using only _log_* passes" {
  cat > "${REPO_DIR}/.claude/scripts/clean.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
source ./lib/log.sh
main() {
  _log_info svc summary count=1
}
main "$@"
BASH
  run "$(script check-log-helper-usage.sh)" --scripts-dir "${REPO_DIR}/.claude/scripts"
  assert_success
  assert_output --partial "clean"
}

@test "bare printf without marker fails with line number" {
  cat > "${REPO_DIR}/.claude/scripts/dirty.sh" <<'BASH'
#!/usr/bin/env bash
main() {
  printf 'hello\n'
}
main "$@"
BASH
  run "$(script check-log-helper-usage.sh)" --scripts-dir "${REPO_DIR}/.claude/scripts"
  assert_failure 1
  assert_output --partial "dirty.sh:3: bare printf"
  assert_output --partial "1 violation"
}

@test "bare echo without marker fails" {
  cat > "${REPO_DIR}/.claude/scripts/dirty.sh" <<'BASH'
#!/usr/bin/env bash
main() {
  echo "hello"
}
main "$@"
BASH
  run "$(script check-log-helper-usage.sh)" --scripts-dir "${REPO_DIR}/.claude/scripts"
  assert_failure 1
  assert_output --partial "dirty.sh:3: bare echo"
}

@test "printf inside usage() is allowed" {
  cat > "${REPO_DIR}/.claude/scripts/with_usage.sh" <<'BASH'
#!/usr/bin/env bash
usage() {
  printf 'Usage: %s\n' "$0"
  echo "extra help"
}
main() {
  :
}
main "$@"
BASH
  run "$(script check-log-helper-usage.sh)" --scripts-dir "${REPO_DIR}/.claude/scripts"
  assert_success
  assert_output --partial "clean"
}

@test "file-wide # log-allow:script marker skips file" {
  cat > "${REPO_DIR}/.claude/scripts/allowed.sh" <<'BASH'
#!/usr/bin/env bash
# log-allow:script -- intentional data product
main() {
  printf 'data\n'
  echo "more data"
}
main "$@"
BASH
  run "$(script check-log-helper-usage.sh)" --scripts-dir "${REPO_DIR}/.claude/scripts"
  assert_success
  assert_output --partial "clean"
}

@test "block markers log-allow:start..end suppress violations inside" {
  cat > "${REPO_DIR}/.claude/scripts/blocked.sh" <<'BASH'
#!/usr/bin/env bash
main() {
  # log-allow:start
  printf 'allowed table row\n'
  echo "another allowed line"
  # log-allow:end
  printf 'denied outside block\n'
}
main "$@"
BASH
  run "$(script check-log-helper-usage.sh)" --scripts-dir "${REPO_DIR}/.claude/scripts"
  assert_failure 1
  assert_output --partial "blocked.sh:7: bare printf"
  refute_output --partial "blocked.sh:4"
  refute_output --partial "blocked.sh:5"
  assert_output --partial "1 violation"
}

@test "multiple violations across files are all reported" {
  cat > "${REPO_DIR}/.claude/scripts/a.sh" <<'BASH'
#!/usr/bin/env bash
echo "a1"
BASH
  cat > "${REPO_DIR}/.claude/scripts/b.sh" <<'BASH'
#!/usr/bin/env bash
printf 'b1\n'
echo "b2"
BASH
  run "$(script check-log-helper-usage.sh)" --scripts-dir "${REPO_DIR}/.claude/scripts"
  assert_failure 1
  assert_output --partial "a.sh:2"
  assert_output --partial "b.sh:2"
  assert_output --partial "b.sh:3"
  assert_output --partial "3 violation"
}

@test "lib/ subdirectory is NOT scanned (only top-level *.sh)" {
  mkdir -p "${REPO_DIR}/.claude/scripts/lib"
  cat > "${REPO_DIR}/.claude/scripts/lib/log.sh" <<'BASH'
#!/usr/bin/env bash
echo "internal log helper"
BASH
  run "$(script check-log-helper-usage.sh)" --scripts-dir "${REPO_DIR}/.claude/scripts"
  assert_success
  assert_output --partial "0 script"
}

@test "real repo passes the lint (smoke against actual docker_harness)" {
  run "$(script check-log-helper-usage.sh)"
  assert_success
  assert_output --partial "clean"
}
