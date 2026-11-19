#!/usr/bin/env bats
#
# deny_ai_attribution_commit_spec.bats -- PreToolUse Bash hook
# (.claude/hooks/deny_ai_attribution_commit.sh) denies a `git commit` /
# `gh pr merge` whose message carries an AI attribution marker, before the
# command runs (base#1988). Marker strings are built from parts at runtime so
# this spec never carries a literal one.

load '../lib/test_helper'

setup() {
  REPO="$(mktemp -d)"
}

teardown() {
  rm -rf "${REPO}"
}

# run_hook <cmd> -- feed the hook the PreToolUse stdin JSON, built with jq so
# a command holding double quotes stays valid JSON.
run_hook() {
  local json
  json="$(jq -n --arg c "$1" --arg d "${REPO}" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$d}')"
  run "$(hook deny_ai_attribution_commit.sh)" <<< "${json}"
}

@test "git commit -m with a co-author trailer is denied naming the marker; a clean one is silent" {
  local trailer
  trailer="Co-Authored-By: $(printf '%s' Cla ude) <noreply@$(printf '%s' anth ropic).com>"
  run_hook "git commit -m feat -m \"${trailer}\""
  assert_permission_decision "deny"
  assert_output --partial "Co-Authored-By"

  run_hook 'git commit -m "feat: add the .claude/hooks guard"'
  assert_silent
}

@test "git commit -F <file> whose file carries a generated-with line is denied naming the marker" {
  printf 'feat: add x\n\n%s with [%s Code](https://x)\n' \
    "Gene$(printf '%s' rated)" "Cla$(printf '%s' ude)" > "${REPO}/msg.txt"
  run_hook 'git commit -F msg.txt'
  assert_permission_decision "deny"
  assert_output --partial "Generated with"
}
