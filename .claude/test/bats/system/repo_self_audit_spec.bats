#!/usr/bin/env bats
#
# System level (ISTQB): the whole delivered framework, end-to-end. Unit
# specs exercise each audit script against synthetic fixtures; these
# assert the ACTUAL docker_harness repo passes its own structural gates,
# so real drift (a script added without a CONTEXT.md tree entry, a
# CLAUDE.md that outgrew its ceiling, a helper that bypasses lib/log.sh)
# fails here as a system regression. Mirrors the ci.sh tree-check /
# ceiling-check / log-helper-check targets, run as part of the bats suite.

load '../lib/test_helper'

@test "system: CONTEXT.md .claude/ tree aligns with the real filesystem" {
  run "$(script check-claude-md-tree.sh)" "${PROJECT_ROOT}/CONTEXT.md"
  assert_success
  assert_output --partial "aligned"
}

@test "system: CLAUDE.md stays within its line / section ceilings" {
  run "$(script check-claude-md-ceiling.sh)" "${PROJECT_ROOT}/CLAUDE.md"
  assert_success
}

@test "system: .claude/scripts adopt the lib/log.sh helper" {
  run "$(script check-log-helper-usage.sh)" --scripts-dir "${PROJECT_ROOT}/.claude/scripts"
  assert_success
}
