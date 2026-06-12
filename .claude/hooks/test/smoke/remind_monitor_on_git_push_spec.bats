#!/usr/bin/env bats

# Covers remind_monitor_on_git_push.sh (refs #157) — fires a CI-watch
# reminder when a `git push` re-pushes / force-pushes an existing PR
# branch (CI re-runs but no `gh pr create` event covers it). Silent on
# initial -u pushes, main pushes, tag pushes, and non-push commands.

load '../lib/test_helper'

fire() {
  run "$(hook remind_monitor_on_git_push.sh)" <<< "{\"tool_input\":{\"command\":\"$1\"}}"
}

@test "fires on git push --force-with-lease" {
  fire "git push --force-with-lease"
  assert_message_contains "wait-pr-ci"
}

@test "silent on git push -u origin feat/x (initial push)" {
  fire "git push -u origin feat/x"
  assert_silent
}

@test "silent on git push --set-upstream origin feat/x" {
  fire "git push --set-upstream origin feat/x"
  assert_silent
}

@test "silent on git push origin main (doc-only direct)" {
  fire "git push origin main"
  assert_silent
}

@test "fires on plain git push (re-push to existing upstream)" {
  fire "git push"
  assert_message_contains "wait-pr-ci"
}

@test "fires on git push origin feat/x without -u (re-push)" {
  fire "git push origin feat/x"
  assert_message_contains "wait-pr-ci"
}

@test "fires on git -C <dir> push --force-with-lease" {
  fire "git -C worktree/docker_harness-9 push --force-with-lease"
  assert_message_contains "wait-pr-ci"
}

@test "silent on version-tag push (git push origin vX.Y.Z)" {
  fire "git push origin v1.2.3"
  assert_silent
}

@test "silent on non-push git command (git status)" {
  fire "git status"
  assert_silent
}

@test "silent on non-git command (ls)" {
  fire "ls -la"
  assert_silent
}

@test "silent on git push --tags (bulk tag push, not a PR branch)" {
  fire "git push --tags"
  assert_silent
}
