#!/usr/bin/env bats

# Covers enforce_local_full_ci_before_pr.sh (refs #176) — blocks
# `gh pr create` / `gh pr ready` unless local CI passed on HEAD (a
# marker file exists) or only docs changed since the last green.

load '../lib/test_helper'

# mk_repo — create a temp git repo with one commit; echo its path.
mk_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "${dir}" init -q -b main
  git -C "${dir}" config user.email t@t
  git -C "${dir}" config user.name t
  # Mirror the real repo: marker state is gitignored, so it never
  # appears in a `git diff` (the marker file must not pollute the
  # doc-only-since-green check).
  echo ".claude/state/" > "${dir}/.gitignore"
  echo "code" > "${dir}/script.sh"
  # A CI mechanism so the gate applies (post-#208 it fail-opens for
  # repos with no detectable CI). justfile.ci marks a base-style repo.
  printf 'test:\n\t:\n' > "${dir}/justfile.ci"
  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m init
  echo "${dir}"
}

# head_sha <repo>
head_sha() { git -C "$1" rev-parse HEAD; }

# commit_file <repo> <path> <content> <msg> — add a file + commit.
commit_file() {
  local repo="$1" path="$2" content="$3" msg="$4"
  mkdir -p "${repo}/$(dirname "${path}")"
  printf '%s\n' "${content}" > "${repo}/${path}"
  git -C "${repo}" add -A
  git -C "${repo}" commit -q -m "${msg}"
}

# mark <repo> <sha> — write the local-ci-pass marker for <sha>.
mark() {
  mkdir -p "$1/.claude/state/local-ci-pass"
  touch "$1/.claude/state/local-ci-pass/$2.ok"
}

# fire <cmd> <cwd>
fire() {
  run "$(hook enforce_local_full_ci_before_pr.sh)" \
    <<< "{\"tool_input\":{\"command\":\"$1\"},\"cwd\":\"$2\"}"
}

@test "denies gh pr create when HEAD has no local-ci marker" {
  local repo
  repo="$(mk_repo)"
  fire "gh pr create --title T --body-file /tmp/x.md" "${repo}"
  assert_permission_decision "deny"
}

@test "allows gh pr create when marker for exact HEAD exists" {
  local repo sha
  repo="$(mk_repo)"
  sha="$(head_sha "${repo}")"
  mark "${repo}" "${sha}"
  fire "gh pr create --title T --body-file /tmp/x.md" "${repo}"
  assert_silent
}

@test "silent on non-trigger gh pr view" {
  local repo
  repo="$(mk_repo)"
  fire "gh pr view 5" "${repo}"
  assert_silent
}

@test "allows when only CHANGELOG.md changed since the green marker" {
  local repo green
  repo="$(mk_repo)"
  green="$(head_sha "${repo}")"
  mark "${repo}" "${green}"
  commit_file "${repo}" "doc/changelog/CHANGELOG.md" "- entry" "docs: changelog"
  fire "gh pr create --title T --body-file /tmp/x.md" "${repo}"
  assert_silent
}

@test "denies when a .sh file changed since the green marker" {
  local repo green
  repo="$(mk_repo)"
  green="$(head_sha "${repo}")"
  mark "${repo}" "${green}"
  commit_file "${repo}" "other.sh" "echo new" "feat: code change"
  fire "gh pr create --title T --body-file /tmp/x.md" "${repo}"
  assert_permission_decision "deny"
}

@test "allows with LOCAL_CI_ACK matching HEAD" {
  local repo sha
  repo="$(mk_repo)"
  sha="$(head_sha "${repo}")"
  fire "LOCAL_CI_ACK=${sha} gh pr create --title T --body-file /tmp/x.md" "${repo}"
  assert_silent
}

@test "denies with LOCAL_CI_ACK not matching HEAD" {
  local repo
  repo="$(mk_repo)"
  fire "LOCAL_CI_ACK=deadbeefdeadbeef gh pr create --title T --body-file /tmp/x.md" "${repo}"
  assert_permission_decision "deny"
}

@test "gh pr ready also gated (no marker -> deny)" {
  local repo
  repo="$(mk_repo)"
  fire "gh pr ready 5" "${repo}"
  assert_permission_decision "deny"
}

@test "silent (fail safe) when cwd is not a git repo" {
  local dir
  dir="$(mktemp -d)"
  fire "gh pr create --title T --body-file /tmp/x.md" "${dir}"
  assert_silent
}

@test "allows when only doc/ + TEST.md changed since the green marker" {
  local repo green
  repo="$(mk_repo)"
  green="$(head_sha "${repo}")"
  mark "${repo}" "${green}"
  commit_file "${repo}" "doc/foo.md" "x" "docs: foo"
  commit_file "${repo}" "doc/test/TEST.md" "y" "docs: test md"
  fire "gh pr create --title T --body-file /tmp/x.md" "${repo}"
  assert_silent
}

@test "fail-open: repo with no detectable CI mechanism is silent (refs #208)" {
  # No .claude/test/Makefile, no justfile.ci, no root justfile -> the
  # gate has nothing to verify against, so it must not block.
  local repo
  repo="$(mktemp -d)"
  git -C "${repo}" init -q -b main
  git -C "${repo}" config user.email t@t
  git -C "${repo}" config user.name t
  echo x > "${repo}/f"
  git -C "${repo}" add -A
  git -C "${repo}" commit -q -m init
  fire "gh pr create --title T --body-file /tmp/x.md" "${repo}"
  assert_silent
  rm -rf "${repo}"
}
