#!/usr/bin/env bats

load '../lib/test_helper'

# Fix CLAUDE_PROJECT_DIR for tests so the hook has a stable workspace
# anchor independent of where the tests run. Derived from
# ${BATS_TEST_DIRNAME} so the spec is portable across clones / users
# (refs #143).
setup() {
  export CLAUDE_PROJECT_DIR="$(cd "${BATS_TEST_DIRNAME}/../../../.." && pwd -P)"
}

@test "allows rm <relative file> (workspace cwd assumed)" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm build.log"}}'
  assert_permission_decision "allow"
}

@test "allows rm subdir/file.txt" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm subdir/file.txt"}}'
  assert_permission_decision "allow"
}

@test "allows rm /tmp/foo.sh" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm /tmp/foo.sh"}}'
  assert_permission_decision "allow"
}

@test "allows rm -rf /tmp/dir" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm -rf /tmp/dir"}}'
  assert_permission_decision "allow"
}

@test "allows rm <absolute path under workspace>" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< "{\"tool_input\":{\"command\":\"rm ${CLAUDE_PROJECT_DIR}/foo.txt\"}}"
  assert_permission_decision "allow"
}

@test "allows rm -- --weird-name (after -- separator)" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm -- --weird-name"}}'
  assert_permission_decision "allow"
}

@test "silent on rm /etc/passwd (outside workspace)" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm /etc/passwd"}}'
  assert_silent
}

@test "silent on rm /usr/bin/foo (outside workspace)" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm /usr/bin/foo"}}'
  assert_silent
}

@test "silent on rm /home/yunchien/.bashrc (home outside workspace)" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm /home/yunchien/.bashrc"}}'
  assert_silent
}

@test "silent on rm ~/.ssh/id_rsa (~ rejected)" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm ~/.ssh/id_rsa"}}'
  assert_silent
}

@test "silent on rm \$HOME/.bashrc (\$ rejected)" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm $HOME/.bashrc"}}'
  assert_silent
}

@test "silent on rm \`pwd\`/file (backtick rejected)" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm `pwd`/file"}}'
  assert_silent
}

@test "silent on rm ../../etc/passwd (.. traversal rejected)" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm ../../etc/passwd"}}'
  assert_silent
}

@test "silent on rm /tmp/foo && rm /etc/passwd (chain rejected)" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm /tmp/foo && rm /etc/passwd"}}'
  assert_silent
}

@test "silent on rm /tmp/foo | xargs (pipe rejected)" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm /tmp/foo | xargs ls"}}'
  assert_silent
}

@test "silent on non-rm command (ls -la)" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"ls -la /tmp"}}'
  assert_silent
}

@test "silent on rmdir (different command)" {
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rmdir empty/"}}'
  assert_silent
}

@test "silent on empty CLAUDE_PROJECT_DIR (defensive)" {
  unset CLAUDE_PROJECT_DIR
  run "$(hook auto_allow_rm_in_workspace.sh)" <<< '{"tool_input":{"command":"rm foo.txt"}}'
  assert_silent
}
