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
  STUB="$(mktemp -d)"
  AI="Cla$(printf '%s' ude)"
  TRAILER="Co-Authored-By: ${AI} <bot@example.invalid>"
}

teardown() {
  rm -rf "${REPO}" "${STUB}"
}

# run_hook <cmd> -- feed the hook the PreToolUse stdin JSON, built with jq so
# a command holding double quotes stays valid JSON.
run_hook() {
  local json
  json="$(jq -n --arg c "$1" --arg d "${REPO}" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$d}')"
  run "$(hook deny_ai_attribution_commit.sh)" <<< "${json}"
}

assert_denied_naming() {
  assert_permission_decision "deny"
  assert_message_contains "carries an AI attribution marker: '$1'"
}

@test "git commit -m with a co-author trailer is denied naming the marker; a clean one is silent" {
  run_hook "git commit -m feat -m \"${TRAILER}\""
  assert_denied_naming "Co-Authored-By: ${AI}"

  run_hook 'git commit -m "feat: add the .claude/hooks guard"'
  assert_silent
}

@test "git commit -F <file> whose file carries a generated-with line is denied naming the marker" {
  printf 'feat: add x\n\n%s with [%s Code](https://x)\n' \
    "Gene$(printf '%s' rated)" "${AI}" > "${REPO}/msg.txt"
  run_hook 'git commit -F msg.txt'
  assert_denied_naming "Generated with [${AI} Code"
}

@test "a read-only git log --grep whose search text names commit and a marker is silent" {
  run_hook "git log --grep='commit message containing ${TRAILER}'"
  assert_silent
}

# stub_gh <pr5-body> [exit] -- a gh on PATH that logs "<cwd>|<args>" to
# ${STUB}/gh.log, prints <pr5-body> when its args name PR 5 and a clean body
# for any other PR, then exits [exit] (default 0).
stub_gh() {
  printf '%s\n' "$1" > "${STUB}/body5.txt"
  cat > "${STUB}/gh" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\${PWD}" "\$*" >> "${STUB}/gh.log"
if [[ " \$* " == *" 5 "* ]]; then cat "${STUB}/body5.txt"; else echo "Summary: another PR"; fi
exit ${2:-0}
EOF
  chmod +x "${STUB}/gh"
  export PATH="${STUB}:${PATH}"
}

@test "gh pr merge <n> looks up PR <n> from the command's cwd: a marked body is denied, other PRs are silent" {
  stub_gh "$(printf 'Summary\n\n%s' "${TRAILER}")"
  run_hook 'gh pr merge 5 --merge'
  assert_denied_naming "Co-Authored-By: ${AI}"
  run grep -F "${REPO}|pr view 5 " "${STUB}/gh.log"
  assert_success

  run_hook 'gh pr merge 6 --merge'
  assert_silent
}

@test "gh pr merge with a clean stored body is silent" {
  stub_gh 'Summary: add the .claude/hooks guard'
  run_hook 'gh pr merge 5 --merge'
  assert_silent
}

@test "gh pr merge --repo OWNER/REPO passes the repo to the PR lookup" {
  stub_gh "$(printf 'Summary\n\n%s' "${TRAILER}")"
  run_hook 'gh pr merge 5 --repo OWNER/REPO --merge'
  assert_denied_naming "Co-Authored-By: ${AI}"
  run grep -E -- "--repo OWNER/REPO|-R OWNER/REPO" "${STUB}/gh.log"
  assert_success
}

@test "gh pr merge with a clean explicit --body is silent even when the stored body is marked" {
  stub_gh "$(printf 'Summary\n\n%s' "${TRAILER}")"
  run_hook 'gh pr merge 5 --merge --body "Summary: clean"'
  assert_silent
}

@test "gh pr merge --body-file <file> whose file is marked is denied even when the stored body is clean" {
  stub_gh 'Summary: clean'
  printf 'Summary\n\n%s\n' "${TRAILER}" > "${REPO}/body.md"
  run_hook 'gh pr merge 5 --merge --body-file body.md'
  assert_denied_naming "Co-Authored-By: ${AI}"
}

@test "a PR lookup that prints a marked body and then fails is ignored (fail open)" {
  stub_gh "$(printf 'Summary\n\n%s' "${TRAILER}")" 1
  run_hook 'gh pr merge 5 --merge'
  assert_silent
}

@test "settings.json wires the guard as a PreToolUse Bash hook" {
  run jq -r '.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[].command' \
    "${PROJECT_ROOT}/.claude/settings.json"
  assert_success
  assert_line '$CLAUDE_PROJECT_DIR/.claude/hooks/deny_ai_attribution_commit.sh'
}
