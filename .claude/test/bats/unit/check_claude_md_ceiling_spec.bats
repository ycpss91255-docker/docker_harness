#!/usr/bin/env bats

load '../lib/test_helper'

# Build a fake markdown file with N total lines and S top-level-or-deeper
# `##` headings. Caller passes the path + N + S; we synthesise content
# that satisfies both counts exactly.
#
# Usage:
#   make_fake_md /tmp/x/CLAUDE.md 50 5
make_fake_md() {
  local path="$1"
  local lines="$2"
  local sections="$3"

  mkdir -p "$(dirname "${path}")"
  : > "${path}"

  local i
  for (( i=1; i<=sections; i++ )); do
    printf '## Section %d\n' "${i}" >> "${path}"
  done

  local remaining=$(( lines - sections ))
  for (( i=1; i<=remaining; i++ )); do
    printf 'line %d\n' "${i}" >> "${path}"
  done
}

@test "--help prints usage and exits 0" {
  run "$(script check-claude-md-ceiling.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "MAX_LINES"
  assert_output --partial "MAX_SECTIONS"
}

@test "missing file exits 2" {
  local missing="$(mktemp -d)/CLAUDE.md"
  run "$(script check-claude-md-ceiling.sh)" "${missing}"
  assert_failure 2
  assert_output --partial "file not found"
}

@test "within default ceilings (240/20) exits 0" {
  local repo
  repo="$(mktemp -d)"
  make_fake_md "${repo}/CLAUDE.md" 100 5
  run "$(script check-claude-md-ceiling.sh)" "${repo}/CLAUDE.md"
  assert_success
  assert_output --partial "within 240/20"
}

@test "lines exceed default ceiling exits 1" {
  local repo
  repo="$(mktemp -d)"
  make_fake_md "${repo}/CLAUDE.md" 300 5
  run "$(script check-claude-md-ceiling.sh)" "${repo}/CLAUDE.md"
  assert_failure 1
  assert_output --partial "300 lines"
  assert_output --partial "max 240"
}

@test "sections exceed default ceiling exits 1" {
  local repo
  repo="$(mktemp -d)"
  make_fake_md "${repo}/CLAUDE.md" 100 25
  run "$(script check-claude-md-ceiling.sh)" "${repo}/CLAUDE.md"
  assert_failure 1
  assert_output --partial "25"
  assert_output --partial "sections"
  assert_output --partial "max 20"
}

@test "MAX_LINES env override (tighter) triggers FAIL" {
  local repo
  repo="$(mktemp -d)"
  make_fake_md "${repo}/CLAUDE.md" 100 5
  MAX_LINES=50 run "$(script check-claude-md-ceiling.sh)" "${repo}/CLAUDE.md"
  assert_failure 1
  assert_output --partial "100 lines"
  assert_output --partial "max 50"
}

@test "MAX_SECTIONS env override (tighter) triggers FAIL" {
  local repo
  repo="$(mktemp -d)"
  make_fake_md "${repo}/CLAUDE.md" 100 5
  MAX_SECTIONS=3 run "$(script check-claude-md-ceiling.sh)" "${repo}/CLAUDE.md"
  assert_failure 1
  assert_output --partial "5"
  assert_output --partial "sections"
  assert_output --partial "max 3"
}
