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
