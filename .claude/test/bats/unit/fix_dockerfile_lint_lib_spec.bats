#!/usr/bin/env bats

load '../lib/test_helper'

@test "--help prints usage and exits 0" {
  run "$(script fix-dockerfile-lint-lib.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--branch"
}

@test "missing --branch exits 2" {
  run "$(script fix-dockerfile-lint-lib.sh)"
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"arg":"--branch"'
}

@test "unknown arg exits 2" {
  run "$(script fix-dockerfile-lint-lib.sh)" --bogus
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
}

@test "--dry-run prints plan for all default repos and exits 0" {
  run "$(script fix-dockerfile-lint-lib.sh)" --branch chore/base-v0.28.2 --dry-run
  assert_success
  assert_output --partial '"body":"dry_run_cmd"'
  assert_output --partial '"repo":"ai_agent"'
  assert_output --partial '"repo":"ros_distro"'
  assert_output --partial '"branch":"chore/base-v0.28.2"'
  assert_output --partial '"body":"summary"'
  assert_output --partial '"patched":"0"'
  assert_output --partial '"failed":"0"'
}

@test "--repos CSV narrows the repo list" {
  run "$(script fix-dockerfile-lint-lib.sh)" --branch chore/base-v0.28.2 --repos ai_agent,claude_code --dry-run
  assert_success
  assert_output --partial '"repo":"ai_agent"'
  assert_output --partial '"repo":"claude_code"'
  refute_output --partial '"repo":"ros_distro"'
}

@test "--org overrides default owner in dry-run output" {
  run "$(script fix-dockerfile-lint-lib.sh)" --branch chore/base-v0.28.2 --org other-org --repos foo --dry-run
  assert_success
  assert_output --partial '"org":"other-org"'
  refute_output --partial '"org":"ycpss91255-docker"'
}
