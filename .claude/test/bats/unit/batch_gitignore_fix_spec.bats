#!/usr/bin/env bats

load '../lib/test_helper'

@test "--help prints usage and exits 0" {
  run "$(script batch-gitignore-fix.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--why"
  assert_output --partial "--dry-run"
}

@test "missing --why-file and --why exits 2" {
  run "$(script batch-gitignore-fix.sh)" --dry-run
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"arg":"--why-file|--why"'
}

@test "unknown arg exits 2" {
  run "$(script batch-gitignore-fix.sh)" --bogus
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
  assert_output --partial '"arg":"--bogus"'
}

@test "--dry-run prints would-do line per repo without mutating" {
  run "$(script batch-gitignore-fix.sh)" \
    --why "test" --dry-run --only agent/ai_agent,template
  assert_success
  assert_output --partial '"body":"dry_run_cmd"'
  assert_output --partial '"repo":"agent/ai_agent"'
  assert_output --partial '"repo":"template"'
  refute_output --partial '"severity_text":"ERROR"'
}

@test "--only narrows to listed repos in dry-run" {
  run "$(script batch-gitignore-fix.sh)" \
    --why "test" --dry-run --only agent/ai_agent
  assert_success
  assert_output --partial '"repo":"agent/ai_agent"'
  refute_output --partial "env/ros_noetic"
  refute_output --partial '"repo":"template"'
}
