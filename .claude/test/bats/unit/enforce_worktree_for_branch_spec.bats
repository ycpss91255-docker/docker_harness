#!/usr/bin/env bats

load '../lib/test_helper'

# enforce_worktree_for_branch.sh -- PreToolUse Bash hook that DENIES
# `git checkout -b|-B <branch>` when invoked from the main checkout
# (i.e. not from inside a worktree). The rule: non-main work must live
# in `<workspace>/worktree/<repo>-<N>/` so the main checkout keeps
# ff-tracking origin/main HEAD (CLAUDE.md > Git 工作流程 > 主 checkout
# 狀態 (Git workflow > main checkout state), refs PR #89).
#
# Detection method:
#   - command matches `git [-C <path>] checkout (-b|-B) <branch>`
#   - resolve target git dir: `-C <path>` arg, or cwd
#   - if `git -C <dir> rev-parse --git-dir` == `--git-common-dir` -> main
#     checkout -> deny
#   - if they differ -> inside a worktree -> silent
#
# Lift mechanism: same `/tmp` checkpoint protocol as siblings.
# Slug: enforce-worktree-for-branch.

setup() {
  export TMPDIR="${BATS_TEST_TMPDIR}"
  export CLAUDE_SESSION_ID="enforce-worktree-for-branch-spec"

  # Main checkout
  MAIN="$(mktemp -d)"
  git -C "${MAIN}" init -q -b main
  git -C "${MAIN}" config user.email t@t
  git -C "${MAIN}" config user.name t
  echo init > "${MAIN}/README.md"
  git -C "${MAIN}" add -A >/dev/null
  git -C "${MAIN}" commit -q -m init >/dev/null

  # Worktree at MAIN/worktree/feat-1
  mkdir -p "${MAIN}/worktree"
  WT="${MAIN}/worktree/feat-1"
  git -C "${MAIN}" worktree add -q "${WT}" -b feat-1 main >/dev/null 2>&1
}

teardown() {
  rm -rf "${MAIN}"
}

ack_path_for() {
  local cmd="$1"
  local hash
  hash="$(printf '%s' "${cmd}" | sha256sum | awk '{print substr($1, 1, 16)}')"
  echo "${TMPDIR}/claude-checkpoint-enforce-worktree-for-branch-${CLAUDE_SESSION_ID}-${hash}.ack"
}

# ---- positive: branch creation from main checkout denies ----

@test "denies git checkout -b feat/x in main checkout" {
  local cmd="git checkout -b feat/x"
  run "$(hook enforce_worktree_for_branch.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"},\"cwd\":\"${MAIN}\"}"
  assert_permission_decision "deny"
  local md_count
  md_count="$(find "${TMPDIR}" -maxdepth 1 -name 'claude-checkpoint-enforce-worktree-for-branch-*.md' | wc -l)"
  [[ "${md_count}" -ge 1 ]] || {
    echo "expected checkpoint .md in TMPDIR, got ${md_count}" >&2
    ls -la "${TMPDIR}" >&2 || true
    return 1
  }
}

@test "denies git checkout -B feat/x (capital B) in main checkout" {
  run "$(hook enforce_worktree_for_branch.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git checkout -B feat/x\"},\"cwd\":\"${MAIN}\"}"
  assert_permission_decision "deny"
}

@test "denies git -C <main-path> checkout -b feat/x (via -C arg)" {
  run "$(hook enforce_worktree_for_branch.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git -C ${MAIN} checkout -b feat/x\"},\"cwd\":\"/tmp\"}"
  assert_permission_decision "deny"
}

@test "deny reason mentions git worktree add" {
  run "$(hook enforce_worktree_for_branch.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git checkout -b feat/x\"},\"cwd\":\"${MAIN}\"}"
  assert_success
  local reason
  reason="$(echo "${output}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
  [[ "${reason}" == *"git worktree add"* ]] || {
    echo "expected reason to mention 'git worktree add', got: ${reason}" >&2
    return 1
  }
}

# ---- negative: from inside a worktree, falls through ----

@test "silent on git checkout -b inside a worktree" {
  run "$(hook enforce_worktree_for_branch.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git checkout -b sub-feat\"},\"cwd\":\"${WT}\"}"
  assert_silent
}

@test "silent on git -C <worktree-path> checkout -b" {
  run "$(hook enforce_worktree_for_branch.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git -C ${WT} checkout -b sub-feat\"},\"cwd\":\"/tmp\"}"
  assert_silent
}

# ---- negative: non-branch-creation forms fall through ----

@test "silent on git checkout main (switch existing branch, no -b)" {
  run "$(hook enforce_worktree_for_branch.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git checkout main\"},\"cwd\":\"${MAIN}\"}"
  assert_silent
}

@test "silent on git checkout -- file.txt (path restore)" {
  run "$(hook enforce_worktree_for_branch.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git checkout -- file.txt\"},\"cwd\":\"${MAIN}\"}"
  assert_silent
}

@test "silent on git checkout some-existing-branch" {
  git -C "${MAIN}" branch existing-feat main 2>/dev/null || true
  run "$(hook enforce_worktree_for_branch.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git checkout existing-feat\"},\"cwd\":\"${MAIN}\"}"
  assert_silent
}

@test "silent on unrelated commands (git status)" {
  run "$(hook enforce_worktree_for_branch.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git status\"},\"cwd\":\"${MAIN}\"}"
  assert_silent
}

@test "silent on empty command" {
  run "$(hook enforce_worktree_for_branch.sh)" \
    <<< "{\"tool_input\":{\"command\":\"\"},\"cwd\":\"${MAIN}\"}"
  assert_silent
}

@test "silent when cwd is not a git repo" {
  local notrepo
  notrepo="$(mktemp -d)"
  run "$(hook enforce_worktree_for_branch.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git checkout -b feat/x\"},\"cwd\":\"${notrepo}\"}"
  assert_silent
  rm -rf "${notrepo}"
}

# ---- ack-bypass + hash isolation ----

@test "allows same checkout -b after ack file exists" {
  local cmd="git checkout -b feat/x"
  local ack
  ack="$(ack_path_for "${cmd}")"
  : > "${ack}"
  run "$(hook enforce_worktree_for_branch.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"},\"cwd\":\"${MAIN}\"}"
  assert_permission_decision "allow"
  local reason
  reason="$(echo "${output}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
  [[ "${reason}" == *"previously acked"* ]] || {
    echo "expected 'previously acked' in reason, got: ${reason}" >&2
    return 1
  }
}

@test "ack for different branch does NOT bypass deny" {
  local other_ack
  other_ack="$(ack_path_for "git checkout -b other-branch")"
  : > "${other_ack}"
  run "$(hook enforce_worktree_for_branch.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git checkout -b feat/x\"},\"cwd\":\"${MAIN}\"}"
  assert_permission_decision "deny"
}
