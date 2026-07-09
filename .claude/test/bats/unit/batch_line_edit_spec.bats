#!/usr/bin/env bats

# Covers .claude/scripts/batch-line-edit.sh (refs #169) — the first
# preset over batch-mutation-pr.sh: append a line to a file across
# repos if absent. Tests the deterministic surface (arg validation +
# --dry-run delegation).

load '../lib/test_helper'

@test "--help prints usage and exits 0" {
  run "$(script batch-line-edit.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--file"
  assert_output --partial "--line"
}

@test "missing --file exits 2" {
  run "$(script batch-line-edit.sh)" --line "x" --why y --dry-run
  assert_failure 2
  assert_output --partial '"arg":"--file"'
}

@test "missing --line exits 2" {
  run "$(script batch-line-edit.sh)" --file .gitignore --why y --dry-run
  assert_failure 2
  assert_output --partial '"arg":"--line"'
}

@test "--dry-run delegates to the engine (shows repos + plan)" {
  run "$(script batch-line-edit.sh)" --file .gitignore --line "CLAUDE.md" --why test \
    --dry-run --only template
  assert_success
  assert_output --partial '"body":"dry_run_cmd"'
  assert_output --partial '"repo":"template"'
  refute_output --partial '"severity_text":"ERROR"'
}
