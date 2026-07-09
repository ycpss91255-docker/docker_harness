#!/usr/bin/env bats

load '../lib/test_helper'

# ---- silent on non-merge / unrelated commands ----

@test "silent on non-gh command" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"echo hello"}}'
  assert_silent
}

@test "silent on gh pr view" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"gh pr view 89 --json state"}}'
  assert_silent
}

@test "silent on gh pr checks" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"gh pr checks 89"}}'
  assert_silent
}

@test "silent on gh pr create" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"gh pr create --title T --body-file /tmp/x.md"}}'
  assert_silent
}

@test "silent on git pull (already syncing main)" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"git pull --ff-only origin main"}}'
  assert_silent
}

@test "silent on empty tool_input" {
  run "$(hook remind_main_sync.sh)" <<< '{}'
  assert_silent
}

@test "silent on non-Bash tool_input shape" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"file_path":"/tmp/x.md"}}'
  assert_silent
}

# ---- fires on gh pr merge ----

@test "fires immediate variant on plain gh pr merge" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"gh pr merge 89"}}'
  assert_message_contains "PR merged"
  assert_message_contains "git pull --ff-only origin main"
}

@test "fires immediate variant on gh pr merge --squash --delete-branch" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"gh pr merge 89 --squash --delete-branch"}}'
  assert_message_contains "PR merged"
  assert_message_contains "git pull --ff-only origin main"
}

@test "fires immediate variant on gh pr merge --merge" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"gh pr merge 89 --merge"}}'
  assert_message_contains "PR merged"
}

@test "fires immediate variant on gh pr merge --rebase" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"gh pr merge 89 --rebase"}}'
  assert_message_contains "PR merged"
}

# ---- queued variant for --auto ----

@test "fires queued variant on gh pr merge --auto" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"gh pr merge 89 --auto --squash"}}'
  assert_message_contains "Auto-merge queued"
  assert_message_contains "After CI passes"
  assert_message_contains "git"
  assert_message_contains "pull --ff-only origin main"
}

@test "fires queued variant on gh pr merge --auto --delete-branch --squash" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"gh pr merge 89 --auto --delete-branch --squash"}}'
  assert_message_contains "Auto-merge queued"
}

# ---- with explicit -R / --repo ----

@test "fires on gh pr merge with -R owner/repo" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"gh pr merge 89 -R ycpss91255-docker/docker_harness --squash"}}'
  assert_message_contains "PR merged"
}

@test "fires on gh pr merge with --repo owner/repo --auto" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"gh pr merge 89 --repo ycpss91255-docker/docker_harness --auto"}}'
  assert_message_contains "Auto-merge queued"
}

# ---- chained commands ----

@test "fires when gh pr merge appears after &&" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"git push && gh pr merge 89 --squash"}}'
  assert_message_contains "PR merged"
}

@test "fires when gh pr merge appears after ;" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"git push; gh pr merge 89"}}'
  assert_message_contains "PR merged"
}

@test "fires when gh pr merge appears inside \$( ... )" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"echo $(gh pr merge 89 --json url)"}}'
  assert_message_contains "PR merged"
}

# ---- false-positive guards (substring inside quoted regions) ----

@test "silent when gh pr merge is inside double-quoted commit message" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"git commit -m \"feat(hook): describe gh pr merge handling\""}}'
  assert_silent
}

@test "silent when gh pr merge is inside single-quoted commit message" {
  run "$(hook remind_main_sync.sh)" <<< "{\"tool_input\":{\"command\":\"git commit -m 'feat: gh pr merge stuff'\"}}"
  assert_silent
}

@test "silent on grep 'gh pr merge' (search literal, not subcommand)" {
  run "$(hook remind_main_sync.sh)" <<< "{\"tool_input\":{\"command\":\"grep -r 'gh pr merge' .claude/hooks\"}}"
  assert_silent
}

@test "silent on echo 'gh pr merge'" {
  run "$(hook remind_main_sync.sh)" <<< "{\"tool_input\":{\"command\":\"echo 'gh pr merge'\"}}"
  assert_silent
}

# ---- mixed: still fires when subcommand is real even if literal also appears in quotes ----

@test "fires when gh pr merge runs alongside a commit message that also mentions it" {
  run "$(hook remind_main_sync.sh)" <<< '{"tool_input":{"command":"git commit -m \"docs: mention gh pr merge\" && gh pr merge 89 --squash"}}'
  assert_message_contains "PR merged"
}
