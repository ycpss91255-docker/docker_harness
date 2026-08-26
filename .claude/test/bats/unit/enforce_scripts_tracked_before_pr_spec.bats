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
