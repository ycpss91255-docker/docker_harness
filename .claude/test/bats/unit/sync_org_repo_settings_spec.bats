#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  SCRIPT_PATH="$(script sync-org-repo-settings.sh)"
  export SCRIPT_PATH
}

@test "--help prints usage and exits 0" {
  run "${SCRIPT_PATH}" --help
  assert_success
  assert_output --partial "sync-org-repo-settings.sh"
  assert_output --partial "Usage:"
  assert_output --partial "--dry-run"
  assert_output --partial "--repo"
}

@test "unknown arg exits 2 with unrecognised_arg body" {
  run "${SCRIPT_PATH}" --bogus
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
  assert_output --partial '"arg":"--bogus"'
}

@test "required_check_for: base -> ci-rollup" {
  source "${SCRIPT_PATH}" --help 2>/dev/null || true
  source "${SCRIPT_PATH}"
  run required_check_for base
  assert_success
  assert_output "ci-rollup"
}

@test "required_check_for: docker_harness -> bats + shellcheck + hadolint" {
  source "${SCRIPT_PATH}"
  run required_check_for docker_harness
  assert_success
  assert_output "bats + shellcheck + hadolint"
}

@test "required_check_for: ros_distro / ros2_distro -> ci-passed" {
  source "${SCRIPT_PATH}"
  run required_check_for ros_distro
  assert_output "ci-passed"
  run required_check_for ros2_distro
  assert_output "ci-passed"
}

@test "required_check_for: ros1_bridge -> ci-summary" {
  source "${SCRIPT_PATH}"
  run required_check_for ros1_bridge
  assert_output "ci-summary"
}

@test "required_check_for: multi_run / template -> test" {
  source "${SCRIPT_PATH}"
  run required_check_for multi_run
  assert_output "test"
  run required_check_for template
  assert_output "test"
}

@test "required_check_for: sam_manager -> build" {
  source "${SCRIPT_PATH}"
  run required_check_for sam_manager
  assert_output "build"
}

@test "required_check_for: .github -> empty (doc-only PRs bypass lint)" {
  source "${SCRIPT_PATH}"
  run required_check_for .github
  assert_success
  assert_output ""
}

@test "required_check_for: default (single-target container) -> call-docker-build / docker-build" {
  source "${SCRIPT_PATH}"
  run required_check_for ai_agent
  assert_output "call-docker-build / docker-build"
  run required_check_for isaac
  assert_output "call-docker-build / docker-build"
  run required_check_for urg_node_noetic
  assert_output "call-docker-build / docker-build"
}

@test "ALL_REPOS lists 23 base-aligned repos" {
  source "${SCRIPT_PATH}"
  [ "${#ALL_REPOS[@]}" -eq 23 ]
}

@test "ALL_REPOS excludes out-of-scope repos (demo-repository, github_runner)" {
  source "${SCRIPT_PATH}"
  local repo
  for repo in "${ALL_REPOS[@]}"; do
    [[ "$repo" != "demo-repository" ]] || {
      echo "demo-repository should not be in ALL_REPOS"
      return 1
    }
    [[ "$repo" != "github_runner" ]] || {
      echo "github_runner should not be in ALL_REPOS (ADR-0012, distinct workflow)"
      return 1
    }
  done
}
