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
  echo "code" > "${dir}/script.sh"
  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m init
  echo "${dir}"
}

# head_sha <repo>
head_sha() { git -C "$1" rev-parse HEAD; }

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
