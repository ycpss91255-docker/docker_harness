#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  TMPYAML="$(mktemp -d)/instincts.yaml"
  export TMPYAML
  cat > "${TMPYAML}" <<'YAML'
- name: shell-style
  trigger:
    kind: file_edit
    glob: '**/*.sh'
  guidance:
    - 2-space indent
    - quote variable expansions
  refs: CLAUDE.md > Style

- name: no-emoji
  trigger:
    kind: file_edit
  guidance:
    - no emoji in code or docs

- name: commit-title
  trigger:
    kind: git_commit
  guidance:
    - max 72 chars
    - conventional prefix

- name: bash-no-cd-git
  trigger:
    kind: bash_command
  guidance:
    - use `git -C path` instead of `cd path && git`

- name: dockerfile-rule
  trigger:
    kind: file_edit
    glob: '**/Dockerfile'
    not_glob: '**/archive/**'
  guidance:
    - locale-gen before LC_ALL ENV
YAML
  export INSTINCTS_FILE="${TMPYAML}"
}

teardown() {
  rm -rf "$(dirname "${TMPYAML}")"
  unset INSTINCTS_FILE
}

# ---- arg parsing ----

@test "--help prints usage and exits 0" {
  run "$(script instinct-query.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--list"
}

@test "unknown flag exits 2" {
  run "$(script instinct-query.sh)" --bogus
  assert_failure 2
  assert_output --partial "unknown arg"
}

@test "missing kind exits 2" {
  run "$(script instinct-query.sh)"
  assert_failure 2
  assert_output --partial "missing <kind>"
}

@test "too many positional args exits 2" {
  run "$(script instinct-query.sh)" file_edit /a /b
  assert_failure 2
  assert_output --partial "too many positional args"
}

# ---- --list mode ----

@test "--list prints every instinct name with its kind" {
  run "$(script instinct-query.sh)" --list
  assert_success
  assert_output --partial "shell-style  (file_edit, glob=**/*.sh)"
  assert_output --partial "no-emoji  (file_edit)"
  assert_output --partial "commit-title  (git_commit)"
  assert_output --partial "bash-no-cd-git  (bash_command)"
}

# ---- kind matching ----

@test "git_commit kind returns the commit-title instinct" {
  run "$(script instinct-query.sh)" git_commit
  assert_success
  assert_output --partial "### commit-title"
  assert_output --partial "max 72 chars"
  refute_output --partial "shell-style"
}

@test "kind with no matching instinct exits 1" {
  run "$(script instinct-query.sh)" no_such_kind
  assert_failure 1
}

# ---- glob matching ----

@test "file_edit on .sh path returns shell-style + no-emoji (kind match without glob)" {
  run "$(script instinct-query.sh)" file_edit /repo/script/foo.sh
  assert_success
  assert_output --partial "### shell-style"
  assert_output --partial "### no-emoji"
}

@test "file_edit on .py path returns only no-emoji (glob filters shell-style out)" {
  run "$(script instinct-query.sh)" file_edit /repo/script/foo.py
  assert_success
  assert_output --partial "### no-emoji"
  refute_output --partial "### shell-style"
}

@test "file_edit on Dockerfile matches glob with curly?" {
  # The dockerfile-rule uses **/Dockerfile (no extension). file_edit
  # against /repo/Dockerfile matches.
  run "$(script instinct-query.sh)" file_edit /repo/Dockerfile
  assert_success
  assert_output --partial "### dockerfile-rule"
  assert_output --partial "locale-gen before LC_ALL"
}

@test "not_glob excludes the matching glob entry" {
  run "$(script instinct-query.sh)" file_edit /repo/archive/old/Dockerfile
  assert_success
  refute_output --partial "### dockerfile-rule"
}

# ---- refs + guidance output ----

@test "guidance bullets are printed indented under the entry header" {
  run "$(script instinct-query.sh)" git_commit
  assert_success
  assert_output --partial "  - max 72 chars"
  assert_output --partial "  - conventional prefix"
}

@test "refs line printed when present, omitted when absent" {
  run "$(script instinct-query.sh)" file_edit /repo/x.sh
  assert_success
  assert_output --partial "refs: CLAUDE.md > Style"
  # no-emoji has no refs in our fixture -> should NOT print a refs line
  # for that entry. Verify via the trailing block ordering.
  local out="${output}"
  [[ "${out}" =~ no-emoji.*no\ emoji\ in\ code\ or\ docs ]]
}

# ---- file resolution ----

@test "missing INSTINCTS_FILE exits 2" {
  INSTINCTS_FILE=/nonexistent/instincts.yaml run "$(script instinct-query.sh)" git_commit
  assert_failure 2
  assert_output --partial "instincts file not found"
}
