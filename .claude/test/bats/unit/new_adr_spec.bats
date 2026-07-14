#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  REPO="$(mktemp -d)"
  (
    cd "${REPO}" || exit 1
    git init -q -b main
    git config user.email t@t
    git config user.name t
    echo init > README.md
    git add README.md >/dev/null
    git commit -q -m init
  ) >/dev/null
}

teardown() {
  rm -rf "${REPO}"
}

run_new_adr() {
  # NOTE: must not be in a subshell -- `run` sets $output/$status in
  # the caller's scope, which a `(...)` group breaks. Each bats test
  # already runs in its own subshell, so cwd change here is scoped to
  # one test.
  cd "${REPO}" || return
  run "$(script new-adr.sh)" "$@"
}

@test "--help exits 0 with usage" {
  run "$(script new-adr.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "<slug>"
}

@test "missing slug exits 2" {
  run "$(script new-adr.sh)"
  assert_failure 2
  assert_output --partial "missing <slug>"
}

@test "invalid slug (uppercase) exits 2" {
  run "$(script new-adr.sh)" Foo-Bar
  assert_failure 2
  assert_output --partial "invalid slug"
}

@test "invalid slug (underscore) exits 2" {
  run "$(script new-adr.sh)" foo_bar
  assert_failure 2
  assert_output --partial "invalid slug"
}

@test "invalid slug (leading dash) exits 2" {
  run "$(script new-adr.sh)" -foo
  assert_failure 2
}

@test "invalid slug (double dash) exits 2" {
  run "$(script new-adr.sh)" foo--bar
  assert_failure 2
  assert_output --partial "invalid slug"
}

@test "slug too long exits 2" {
  local long_slug
  long_slug="$(printf 'a%.0s' {1..81})"
  run "$(script new-adr.sh)" "${long_slug}"
  assert_failure 2
  assert_output --partial "too long"
}

@test "unknown flag exits 2" {
  run "$(script new-adr.sh)" --bogus
  assert_failure 2
  assert_output --partial "unknown flag"
}

@test "first ADR gets number 00000001" {
  run_new_adr foo-bar
  assert_success
  assert_output --partial "00000001-foo-bar.md"
  [[ -f "${REPO}/doc/adr/00000001-foo-bar.md" ]]
}

@test "second ADR gets number 00000002" {
  run_new_adr first-decision
  assert_success
  run_new_adr second-decision
  assert_success
  assert_output --partial "00000002-second-decision.md"
  [[ -f "${REPO}/doc/adr/00000002-second-decision.md" ]]
}

@test "auto-numbering picks max+1 across non-contiguous existing ADRs" {
  mkdir -p "${REPO}/doc/adr"
  echo "stub" > "${REPO}/doc/adr/00000001-a.md"
  echo "stub" > "${REPO}/doc/adr/00000005-b.md"
  echo "stub" > "${REPO}/doc/adr/00000003-c.md"
  run_new_adr next-one
  assert_success
  assert_output --partial "00000006-next-one.md"
}

@test "same slug across different numbers is allowed (auto-numbering)" {
  # Auto-numbering guarantees uniqueness; the slug itself may repeat.
  run_new_adr same-slug
  assert_success
  run_new_adr same-slug
  assert_success
  [[ -f "${REPO}/doc/adr/00000001-same-slug.md" ]]
  [[ -f "${REPO}/doc/adr/00000002-same-slug.md" ]]
}

@test "template body contains all 4 sections" {
  run_new_adr template-test
  assert_success
  local body
  body="$(cat "${REPO}/doc/adr/00000001-template-test.md")"
  [[ "${body}" == *"## Context"* ]]
  [[ "${body}" == *"## Decision"* ]]
  [[ "${body}" == *"## Alternatives"* ]]
  [[ "${body}" == *"## Consequences"* ]]
  [[ "${body}" == *"Status:** Accepted"* ]]
}

@test "title-cases the slug in the H1" {
  run_new_adr entrypoint-single-file
  assert_success
  local first_line
  first_line="$(head -n1 "${REPO}/doc/adr/00000001-entrypoint-single-file.md")"
  [[ "${first_line}" == "# ADR-00000001: Entrypoint Single File" ]]
}

@test "--dry-run does not create the file" {
  run_new_adr --dry-run foo-bar
  assert_success
  assert_output --partial "[dry-run]"
  assert_output --partial "00000001-foo-bar.md"
  [[ ! -e "${REPO}/doc/adr/00000001-foo-bar.md" ]]
}

@test "creates doc/adr/ directory when missing" {
  [[ ! -d "${REPO}/doc/adr" ]]
  run_new_adr bootstrap
  assert_success
  [[ -d "${REPO}/doc/adr" ]]
  [[ -f "${REPO}/doc/adr/00000001-bootstrap.md" ]]
}
