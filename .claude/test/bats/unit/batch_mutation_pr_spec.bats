#!/usr/bin/env bats

# Covers .claude/scripts/batch-mutation-pr.sh (refs #169) — the generic
# cross-repo fanout engine. Tests the deterministic surface (arg
# validation + --dry-run plan); real worktree/push/PR is not exercised
# here (mirrors batch_gitignore_add_line_spec.bats).

load '../lib/test_helper'

setup() {
  TMP="$(mktemp -d)"
  MUT="${TMP}/mutate.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${MUT}"
  chmod +x "${MUT}"
}

teardown() {
  rm -rf "${TMP}"
}

@test "--help prints usage and exits 0" {
  run "$(script batch-mutation-pr.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--mutation"
  assert_output --partial "--pr-title"
  assert_output --partial "--dry-run"
}

@test "missing --mutation exits 2" {
  run "$(script batch-mutation-pr.sh)" --pr-title T --why x --dry-run
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"arg":"--mutation"'
}

@test "non-executable --mutation exits 2" {
  local notexe="${TMP}/plain.txt"
  echo hi > "${notexe}"
  run "$(script batch-mutation-pr.sh)" --mutation "${notexe}" --pr-title T --why x --dry-run
  assert_failure 2
  assert_output --partial '"reason":"not-executable"'
}

@test "missing --pr-title exits 2" {
  run "$(script batch-mutation-pr.sh)" --mutation "${MUT}" --why x --dry-run
  assert_failure 2
  assert_output --partial '"arg":"--pr-title"'
}

@test "missing --why-file and --why exits 2" {
  run "$(script batch-mutation-pr.sh)" --mutation "${MUT}" --pr-title T --dry-run
  assert_failure 2
  assert_output --partial '"arg":"--why-file|--why"'
}

@test "invalid --commit-type exits 2" {
  run "$(script batch-mutation-pr.sh)" --mutation "${MUT}" --pr-title T --why x --commit-type docs --dry-run
  assert_failure 2
  assert_output --partial '"reason":"not-in-fix-feat-chore"'
}

@test "unknown arg exits 2" {
  run "$(script batch-mutation-pr.sh)" --bogus
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
  assert_output --partial '"arg":"--bogus"'
}

@test "--dry-run prints a plan line per repo without mutating" {
  run "$(script batch-mutation-pr.sh)" --mutation "${MUT}" --pr-title "Add badge" --why test \
    --dry-run --only app/realsense_ros2,template
  assert_success
  assert_output --partial '"body":"dry_run_cmd"'
  assert_output --partial '"repo":"app/realsense_ros2"'
  assert_output --partial '"repo":"template"'
  refute_output --partial '"severity_text":"ERROR"'
}

@test "--skip excludes a repo in dry-run" {
  run "$(script batch-mutation-pr.sh)" --mutation "${MUT}" --pr-title T --why x \
    --dry-run --only app/realsense_ros2,template --skip template
  assert_success
  assert_output --partial '"repo":"app/realsense_ros2"'
  refute_output --partial '"repo":"template"'
}

@test "branch derives from --commit-type + --pr-title slug" {
  run "$(script batch-mutation-pr.sh)" --mutation "${MUT}" --pr-title "Add CI badge!" --why x \
    --commit-type feat --dry-run --only template
  assert_success
  assert_output --partial '"branch":"feat/add-ci-badge"'
}

@test "explicit --branch overrides the derived slug" {
  run "$(script batch-mutation-pr.sh)" --mutation "${MUT}" --pr-title "Add CI badge" --why x \
    --branch custom/my-branch --dry-run --only template
  assert_success
  assert_output --partial '"branch":"custom/my-branch"'
}

@test "valid --commit-type fix accepted in dry-run" {
  run "$(script batch-mutation-pr.sh)" --mutation "${MUT}" --pr-title T --why x \
    --commit-type fix --dry-run --only template
  assert_success
  assert_output --partial '"branch":"fix/t"'
}
