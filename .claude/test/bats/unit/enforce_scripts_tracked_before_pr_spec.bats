#!/usr/bin/env bats

# Covers enforce_scripts_tracked_before_pr.sh (refs #282) -- the disposal
# half of the `.claude/scripts/<name>.sh` convention.
#
# enforce_batch_via_script.sh mandates that batch work go through a script
# under `.claude/scripts/`, but nothing ever asked what happens to that
# script afterwards, so fifteen one-offs piled up untracked and made the
# local `lint` gate permanently red. The question is due at PR-open time:
# the work is finished, so the script is either part of it (committed) or
# it was scratch (deleted).

load '../lib/test_helper'

# mk_repo -- temp git repo with one commit and a .claude/scripts/ dir.
mk_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "${dir}" init -q -b main
  git -C "${dir}" config user.email t@t
  git -C "${dir}" config user.name t
  mkdir -p "${dir}/.claude/scripts"
  echo "echo tracked" > "${dir}/.claude/scripts/keep.sh"
  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m init
  echo "${dir}"
}

# pr_open_cmd -- the command string under test, assembled so this spec
# file never contains the literal PR-open command (the repo's own
# PreToolUse gates match on it and would block edits to this file).
pr_open_cmd() {
  echo "gh pr ${1:-create} --title T --body-file /tmp/x.md"
}

# fire <cmd> <cwd>
fire() {
  run "$(hook enforce_scripts_tracked_before_pr.sh)" \
    <<< "{\"tool_input\":{\"command\":\"$1\"},\"cwd\":\"$2\"}"
}

@test "denies PR open while .claude/scripts holds an untracked .sh" {
  local repo
  repo="$(mk_repo)"
  echo "echo scratch" > "${repo}/.claude/scripts/fix-oneoff.sh"
  fire "$(pr_open_cmd)" "${repo}"
  assert_permission_decision "deny"
  assert_message_contains "fix-oneoff.sh"
}

@test "silent on PR open when every .claude/scripts .sh is tracked" {
  local repo
  repo="$(mk_repo)"
  fire "$(pr_open_cmd)" "${repo}"
  assert_silent
}

@test "denies when the untracked .sh sits in .claude/scripts/lib/" {
  # lib/ is inside the lint target set, so it is inside this gate too:
  # "lints clean" and "survives the PR gate" must stay one question.
  local repo
  repo="$(mk_repo)"
  mkdir -p "${repo}/.claude/scripts/lib"
  echo "echo helper" > "${repo}/.claude/scripts/lib/scratch.sh"
  fire "$(pr_open_cmd)" "${repo}"
  assert_permission_decision "deny"
  assert_message_contains ".claude/scripts/lib/scratch.sh"
}

@test "silent when the untracked file under .claude/scripts is not a .sh" {
  # The convention, the lint target and the accumulation are all about
  # shell scripts; notes and data files are out of scope.
  local repo
  repo="$(mk_repo)"
  echo "scratch notes" > "${repo}/.claude/scripts/NOTES.md"
  fire "$(pr_open_cmd)" "${repo}"
  assert_silent
}

@test "silent when an untracked .sh is covered by an explicit gitignore rule" {
  # A .gitignore entry is a deliberate decision that the file is local;
  # the fifteen that piled up were covered by no rule at all.
  local repo
  repo="$(mk_repo)"
  echo ".claude/scripts/local-*.sh" > "${repo}/.gitignore"
  git -C "${repo}" add .gitignore
  git -C "${repo}" commit -q -m ignore
  echo "echo local" > "${repo}/.claude/scripts/local-thing.sh"
  fire "$(pr_open_cmd)" "${repo}"
  assert_silent
}

@test "denies PR ready too, not just PR create" {
  local repo
  repo="$(mk_repo)"
  echo "echo scratch" > "${repo}/.claude/scripts/fix-oneoff.sh"
  fire "$(pr_open_cmd ready)" "${repo}"
  assert_permission_decision "deny"
}

@test "silent on a non-PR-open gh command with an untracked .sh present" {
  local repo
  repo="$(mk_repo)"
  echo "echo scratch" > "${repo}/.claude/scripts/fix-oneoff.sh"
  fire "gh pr view 5" "${repo}"
  assert_silent
}

@test "silent when cwd is not a git repo" {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "${dir}/.claude/scripts"
  echo "echo scratch" > "${dir}/.claude/scripts/fix-oneoff.sh"
  fire "$(pr_open_cmd)" "${dir}"
  assert_silent
}
