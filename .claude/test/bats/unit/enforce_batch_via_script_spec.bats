#!/usr/bin/env bats

load '../lib/test_helper'

# enforce_batch_via_script.sh -- PreToolUse Bash hook that DENIES ad-hoc
# cross-repo for-loops that perform state-changing operations
# (git push|reset|tag|branch -D, or gh issue|pr close|merge|comment --body),
# routing the agent toward a permanent .claude/scripts/<name>.sh wrapper.
#
# Detection:
#   - command matches `for <var> in <values>` (single-line or multi-line)
#   - AND the same command (loop body or post-pipe) contains a mutating
#     git/gh call as listed above
#
# Pass-through silent when:
#   - no for-loop in the command
#   - the loop contains only read-only ops (gh pr view, git log, grep, cat)
#   - empty / unrelated commands
#
# Ack-bypass: pre-existing `.ack` matching sha256(cmd)-16hex flips deny
# to allow with a "previously acked" reason (slug
# `enforce-batch-via-script`; CLAUDE_SESSION_ID-scoped).

setup() {
  export TMPDIR="${BATS_TEST_TMPDIR}"
  export CLAUDE_SESSION_ID="enforce-batch-via-script-spec"
}

ack_path_for() {
  local cmd="$1"
  local hash
  hash="$(printf '%s' "${cmd}" | sha256sum | awk '{print substr($1, 1, 16)}')"
  echo "${TMPDIR}/claude-checkpoint-enforce-batch-via-script-${CLAUDE_SESSION_ID}-${hash}.ack"
}

# ---- positive: for-loop + mutation → deny + write checkpoint ----

@test "denies for-loop with gh issue close" {
  local cmd='for r in ros_distro ros2_distro; do gh issue close 1 -R ycpss91255-docker/$r; done'
  run "$(hook enforce_batch_via_script.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"}}"
  assert_permission_decision "deny"
  local md_count
  md_count="$(find "${TMPDIR}" -maxdepth 1 -name 'claude-checkpoint-enforce-batch-via-script-*.md' | wc -l)"
  [[ "${md_count}" -ge 1 ]] || {
    echo "expected at least one checkpoint .md in TMPDIR, got ${md_count}" >&2
    ls -la "${TMPDIR}" >&2 || true
    return 1
  }
}

@test "denies for-loop with git push origin tag" {
  local cmd='for repo in foo bar; do git -C $repo push origin main; done'
  run "$(hook enforce_batch_via_script.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"}}"
  assert_permission_decision "deny"
}

@test "denies for-loop with git reset --hard" {
  local cmd='for r in a b c; do (cd $r && git reset --hard FETCH_HEAD); done'
  run "$(hook enforce_batch_via_script.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"}}"
  assert_permission_decision "deny"
}

@test "denies for-loop with git branch -D" {
  local cmd='for b in feat1 feat2; do git branch -D $b; done'
  run "$(hook enforce_batch_via_script.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"}}"
  assert_permission_decision "deny"
}

@test "denies for-loop with git tag (mutating)" {
  local cmd='for r in foo bar; do git -C $r tag v1.0.0; done'
  run "$(hook enforce_batch_via_script.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"}}"
  assert_permission_decision "deny"
}

@test "denies for-loop with gh pr merge" {
  local cmd='for n in 1 2 3; do gh pr merge $n --squash; done'
  run "$(hook enforce_batch_via_script.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"}}"
  assert_permission_decision "deny"
}

@test "denies for-loop with gh issue comment --body" {
  local cmd='for n in 1 2; do gh issue comment $n --body=ping; done'
  run "$(hook enforce_batch_via_script.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"}}"
  assert_permission_decision "deny"
}

@test "deny reason mentions permanent script under .claude/scripts/" {
  local cmd='for r in a b; do gh issue close 1 -R ycpss91255-docker/$r; done'
  run "$(hook enforce_batch_via_script.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"}}"
  assert_success
  local reason
  reason="$(echo "${output}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
  [[ "${reason}" == *".claude/scripts/"* ]] || {
    echo "expected reason to mention .claude/scripts/, got: ${reason}" >&2
    return 1
  }
}

@test "denies multi-line for-loop body" {
  local cmd
  printf -v cmd 'for r in a b; do\n  git -C $r push origin main\ndone'
  run "$(hook enforce_batch_via_script.sh)" \
    <<< "{\"tool_input\":{\"command\":$(jq -Rn --arg c "${cmd}" '$c')}}"
  assert_permission_decision "deny"
}

# ---- negative: pass-through silent ----

@test "silent on for-loop with read-only gh pr view" {
  local cmd='for r in ros_distro ros2_distro; do gh pr view 1 -R ycpss91255-docker/$r --json state; done'
  run "$(hook enforce_batch_via_script.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"}}"
  assert_silent
}

@test "silent on for-loop with read-only git log" {
  local cmd='for r in a b; do git -C $r log --oneline -5; done'
  run "$(hook enforce_batch_via_script.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"}}"
  assert_silent
}

@test "silent on for-loop with grep only" {
  local cmd='for f in a.txt b.txt; do grep needle "$f"; done'
  run "$(hook enforce_batch_via_script.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"}}"
  assert_silent
}

@test "silent on standalone git push (no for-loop)" {
  run "$(hook enforce_batch_via_script.sh)" \
    <<< '{"tool_input":{"command":"git push origin main"}}'
  assert_silent
}

@test "silent on standalone gh issue close (no for-loop)" {
  run "$(hook enforce_batch_via_script.sh)" \
    <<< '{"tool_input":{"command":"gh issue close 1 -R ycpss91255-docker/docker_harness"}}'
  assert_silent
}

@test "silent when invoking permanent batch script directly" {
  run "$(hook enforce_batch_via_script.sh)" \
    <<< '{"tool_input":{"command":".claude/scripts/batch-pr-merge.sh ros_distro:5 ros2_distro:6"}}'
  assert_silent
}

@test "silent on git tag delete (-d) inside for-loop" {
  # `git tag -d` is the delete subcommand, not the create one -- treat as
  # read-only-ish housekeeping; same compromise as enforce_semver_tag_via_script.
  local cmd='for t in v1 v2; do git tag -d $t; done'
  run "$(hook enforce_batch_via_script.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"}}"
  assert_silent
}

@test "silent on empty command" {
  run "$(hook enforce_batch_via_script.sh)" \
    <<< '{"tool_input":{"command":""}}'
  assert_silent
}

# ---- ack-bypass + hash isolation ----

@test "allows same for-loop after ack file exists" {
  local cmd='for r in a b; do gh issue close 1 -R ycpss91255-docker/$r; done'
  local ack
  ack="$(ack_path_for "${cmd}")"
  : > "${ack}"
  run "$(hook enforce_batch_via_script.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"}}"
  assert_permission_decision "allow"
  local reason
  reason="$(echo "${output}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
  [[ "${reason}" == *"previously acked"* ]] || {
    echo "expected 'previously acked' in reason, got: ${reason}" >&2
    return 1
  }
}

@test "ack for different command does NOT bypass deny" {
  local other_ack
  other_ack="$(ack_path_for "for r in unrelated; do git push origin main; done")"
  : > "${other_ack}"
  run "$(hook enforce_batch_via_script.sh)" \
    <<< '{"tool_input":{"command":"for r in a b; do gh issue close 1 -R ycpss91255-docker/$r; done"}}'
  assert_permission_decision "deny"
}
