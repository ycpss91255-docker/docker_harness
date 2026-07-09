#!/usr/bin/env bats

load '../lib/test_helper'

# Setup helpers — create a local bare "origin" + a clone, with the
# local main optionally behind origin/main by N commits.

mk_aligned_repo() {
  local base
  base="$(mktemp -d)"
  ORIGIN="${base}/origin.git"
  LOCAL="${base}/local"

  git init -q --bare "${ORIGIN}"
  git clone -q "${ORIGIN}" "${LOCAL}"
  git -C "${LOCAL}" config user.email t@t
  git -C "${LOCAL}" config user.name t

  echo a > "${LOCAL}/a.txt"
  git -C "${LOCAL}" add . >/dev/null
  git -C "${LOCAL}" commit -q -m a
  git -C "${LOCAL}" branch -M main
  git -C "${LOCAL}" push -q -u origin main

  printf '%s\n' "${LOCAL}"
}

# Make local main 1 commit BEHIND origin/main: add a commit, push,
# then reset local back.
mk_behind_repo() {
  local local_dir
  local_dir="$(mk_aligned_repo)"
  echo b > "${local_dir}/b.txt"
  git -C "${local_dir}" add . >/dev/null
  git -C "${local_dir}" commit -q -m b
  git -C "${local_dir}" push -q origin main      # origin now at B
  git -C "${local_dir}" reset --hard -q HEAD^    # local main back to A
  # Also drop the cached origin/main so the hook's git fetch is the
  # one that re-discovers B.
  git -C "${local_dir}" update-ref -d refs/remotes/origin/main || true
  printf '%s\n' "${local_dir}"
}

teardown() {
  if [[ -n "${LOCAL:-}" && -d "${LOCAL}" ]]; then
    rm -rf "$(dirname "${LOCAL}")"
  fi
}

# ---- silent on unrelated commands ----

@test "silent on non-git command" {
  run "$(hook check_main_fresh_before_worktree.sh)" \
    <<< '{"tool_input":{"command":"echo hello"}}'
  assert_silent
}

@test "silent on git status" {
  run "$(hook check_main_fresh_before_worktree.sh)" \
    <<< '{"tool_input":{"command":"git status"}}'
  assert_silent
}

@test "silent on git worktree list (not add)" {
  run "$(hook check_main_fresh_before_worktree.sh)" \
    <<< '{"tool_input":{"command":"git worktree list"}}'
  assert_silent
}

@test "silent on git worktree remove" {
  run "$(hook check_main_fresh_before_worktree.sh)" \
    <<< '{"tool_input":{"command":"git worktree remove worktree/foo"}}'
  assert_silent
}

@test "silent on git worktree add branching from a tag, not main" {
  run "$(hook check_main_fresh_before_worktree.sh)" \
    <<< '{"tool_input":{"command":"git worktree add worktree/foo-1 -b release/v1 v1.0.0"}}'
  assert_silent
}

@test "silent on git worktree add branching from a feature branch (no main token)" {
  run "$(hook check_main_fresh_before_worktree.sh)" \
    <<< '{"tool_input":{"command":"git worktree add worktree/foo-1 -b chore/x feat/base"}}'
  assert_silent
}

@test "silent on empty tool_input" {
  run "$(hook check_main_fresh_before_worktree.sh)" <<< '{}'
  assert_silent
}

# ---- aligned local main: allow ----

@test "silent (allow) when local main aligned with origin/main (main token)" {
  local_dir="$(mk_aligned_repo)"
  run "$(hook check_main_fresh_before_worktree.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git worktree add worktree/foo -b feat/x main\"},\"cwd\":\"${local_dir}\"}"
  assert_silent
}

@test "silent (allow) when local main aligned with origin/main (origin/main token)" {
  local_dir="$(mk_aligned_repo)"
  run "$(hook check_main_fresh_before_worktree.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git worktree add worktree/foo -b feat/x origin/main\"},\"cwd\":\"${local_dir}\"}"
  assert_silent
}

# ---- behind: deny ----

@test "denies when local main is 1 commit behind origin/main (main token)" {
  local_dir="$(mk_behind_repo)"
  run "$(hook check_main_fresh_before_worktree.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git worktree add worktree/foo -b feat/x main\"},\"cwd\":\"${local_dir}\"}"
  assert_permission_decision "deny"
  assert_message_contains "behind origin/main"
  assert_message_contains "pull --ff-only origin main"
}

@test "denies when local main is 1 commit behind origin/main (origin/main token)" {
  local_dir="$(mk_behind_repo)"
  run "$(hook check_main_fresh_before_worktree.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git worktree add worktree/foo -b feat/x origin/main\"},\"cwd\":\"${local_dir}\"}"
  assert_permission_decision "deny"
}

@test "denies with explicit -C work-dir form" {
  local_dir="$(mk_behind_repo)"
  run "$(hook check_main_fresh_before_worktree.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git -C ${local_dir} worktree add worktree/foo -b feat/x main\"}}"
  assert_permission_decision "deny"
}

@test "denies with cd && form" {
  local_dir="$(mk_behind_repo)"
  run "$(hook check_main_fresh_before_worktree.sh)" \
    <<< "{\"tool_input\":{\"command\":\"cd ${local_dir} && git worktree add worktree/foo -b feat/x main\"}}"
  assert_permission_decision "deny"
}

# ---- degraded paths (non-git dir, no origin/main): allow ----

@test "silent when cwd is not a git repo (allow)" {
  local dir
  dir="$(mktemp -d)"
  run "$(hook check_main_fresh_before_worktree.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git worktree add worktree/foo -b feat/x main\"},\"cwd\":\"${dir}\"}"
  assert_silent
  rm -rf "${dir}"
}
