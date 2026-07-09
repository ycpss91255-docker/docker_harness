#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  GH_STUB_DIR="$(mktemp -d)"
  export GH_STUB_DIR
  export PATH="${GH_STUB_DIR}:${PATH}"
  TMP_BODIES="$(mktemp -d)"
  export TMP_BODIES
  export TMPDIR="${TMP_BODIES}"
}

teardown() {
  rm -rf "${GH_STUB_DIR}" "${TMP_BODIES}"
}

# Install a gh shim that succeeds, logs every invocation to calls.log
# (each call separated by --- on its own line), and returns no issues for
# `gh issue list` so existence checks always say "not found".
stub_gh_capture_no_existing() {
  cat > "${GH_STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
{
  printf '%s\n' "$@"
  printf '%s\n' '---'
} >> "${GH_STUB_DIR}/calls.log"
if [[ "$1" == "issue" && "$2" == "list" ]]; then
  exit 0
fi
exit 0
EOF
  chmod +x "${GH_STUB_DIR}/gh"
}

# gh shim that returns one existing-title match for `issue list` (so the
# script skips creating). The matched title is read from the GH_MATCH
# env var.
stub_gh_existing_title() {
  cat > "${GH_STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
{
  printf '%s\n' "$@"
  printf '%s\n' '---'
} >> "${GH_STUB_DIR}/calls.log"
if [[ "$1" == "issue" && "$2" == "list" ]]; then
  printf '%s\n' "${GH_MATCH:-}"
  exit 0
fi
exit 0
EOF
  chmod +x "${GH_STUB_DIR}/gh"
}

stub_gh_create_fails() {
  cat > "${GH_STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
{
  printf '%s\n' "$@"
  printf '%s\n' '---'
} >> "${GH_STUB_DIR}/calls.log"
if [[ "$1" == "issue" && "$2" == "list" ]]; then
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "create" ]]; then
  echo "gh: simulated create failure" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "${GH_STUB_DIR}/gh"
}

# ---- argument parsing ----

@test "--help prints usage and exits 0" {
  run "$(script batch-open-archive-rename-issues.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--owner"
  assert_output --partial "--refs"
  assert_output --partial "--only"
  assert_output --partial "--dry-run"
}

@test "unknown arg exits 2" {
  run "$(script batch-open-archive-rename-issues.sh)" --bogus
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
  assert_output --partial '"arg":"--bogus"'
}

# ---- --dry-run lists exactly 11 issues with the right repo/title shape ----

@test "--dry-run lists all 7 archive + 4 rename issues" {
  run "$(script batch-open-archive-rename-issues.sh)" --dry-run
  assert_success

  # 7 archive entries
  assert_output --partial "ycpss91255-docker/ai_agent"
  assert_output --partial "ycpss91255-docker/claude_code"
  assert_output --partial "ycpss91255-docker/codex_cli"
  assert_output --partial "ycpss91255-docker/gemini_cli"
  assert_output --partial "ycpss91255-docker/ros1_bridge"
  assert_output --partial "ycpss91255-docker/sick_humble"
  assert_output --partial "ycpss91255-docker/sick_noetic"

  # 4 rename entries (old repo is the GitHub target; new is in title)
  assert_output --partial "ycpss91255-docker/urg_node_humble"
  assert_output --partial "urg_node_humble -> urg_node_ros2"
  assert_output --partial "ycpss91255-docker/urg_node_noetic"
  assert_output --partial "urg_node_noetic -> urg_node_ros1"
  assert_output --partial "ycpss91255-docker/realsense_humble"
  assert_output --partial "realsense_humble -> realsense_ros2"
  assert_output --partial "ycpss91255-docker/realsense_noetic"
  assert_output --partial "realsense_noetic -> realsense_ros1"

  # 11 created in summary
  assert_output --partial '"created":"11"'
  assert_output --partial '"failed":"0"'
}

@test "--dry-run writes body files under TMPDIR" {
  run "$(script batch-open-archive-rename-issues.sh)" --dry-run
  assert_success

  [[ -f "${TMP_BODIES}/issue-archive-ai_agent.md" ]]
  [[ -f "${TMP_BODIES}/issue-archive-ros1_bridge.md" ]]
  [[ -f "${TMP_BODIES}/issue-rename-urg_node_humble.md" ]]
  [[ -f "${TMP_BODIES}/issue-rename-realsense_noetic.md" ]]
}

# ---- body content shape ----

@test "archive body has 5 standard sections + parked reason + refs line" {
  run "$(script batch-open-archive-rename-issues.sh)" \
    --dry-run --refs '#86' --only sick_humble
  assert_success

  local body="${TMP_BODIES}/issue-archive-sick_humble.md"
  [[ -f "${body}" ]]
  run cat "${body}"
  assert_output --partial "## Context"
  assert_output --partial "## Problem"
  assert_output --partial "## Proposal"
  assert_output --partial "## Acceptance"
  assert_output --partial "## Out of scope"
  assert_output --partial "covered by env/ros2_distro"
  assert_output --partial "refs #86"
}

@test "rename body has 5 standard sections + new name + ROS version label + refs line" {
  run "$(script batch-open-archive-rename-issues.sh)" \
    --dry-run --refs '#86' --only urg_node_noetic
  assert_success

  local body="${TMP_BODIES}/issue-rename-urg_node_noetic.md"
  [[ -f "${body}" ]]
  run cat "${body}"
  assert_output --partial "## Context"
  assert_output --partial "## Problem"
  assert_output --partial "## Proposal"
  assert_output --partial "## Acceptance"
  assert_output --partial "## Out of scope"
  assert_output --partial "urg_node_ros1"
  assert_output --partial "ROS 1"
  assert_output --partial ".base"
  assert_output --partial "refs #86"
}

@test "body omits refs section when --refs not given" {
  run "$(script batch-open-archive-rename-issues.sh)" \
    --dry-run --only gemini_cli
  assert_success
  run cat "${TMP_BODIES}/issue-archive-gemini_cli.md"
  refute_output --partial "refs "
}

# ---- --only filter ----

@test "--only filters to single archive repo" {
  run "$(script batch-open-archive-rename-issues.sh)" \
    --dry-run --only ai_agent
  assert_success
  assert_output --partial "ai_agent"
  refute_output --partial "claude_code"
  refute_output --partial "urg_node_humble"
  assert_output --partial '"created":"1"'
}

@test "--only filters to multiple slugs across archive + rename groups" {
  run "$(script batch-open-archive-rename-issues.sh)" \
    --dry-run --only sick_humble,urg_node_humble
  assert_success
  assert_output --partial "sick_humble"
  assert_output --partial "urg_node_humble"
  refute_output --partial "ai_agent"
  assert_output --partial '"created":"2"'
}

@test "--only with non-matching slug creates none" {
  run "$(script batch-open-archive-rename-issues.sh)" \
    --dry-run --only nonexistent_repo
  assert_success
  assert_output --partial '"created":"0"'
}

# ---- title format ----

@test "archive title format: 'chore: archive <repo> (out of docker_harness active list)'" {
  run "$(script batch-open-archive-rename-issues.sh)" \
    --dry-run --only ai_agent
  assert_success
  assert_output --partial "chore: archive ai_agent (out of docker_harness active list)"
}

@test "rename title format: 'chore: rename <old> -> <new> (+ .base migration)'" {
  run "$(script batch-open-archive-rename-issues.sh)" \
    --dry-run --only realsense_humble
  assert_success
  assert_output --partial "chore: rename realsense_humble -> realsense_ros2 (+ .base migration)"
}

# ---- gh create invocation (with stub) ----

@test "non-dry-run calls 'gh issue create -R <owner/repo> --title ... --body-file ...'" {
  stub_gh_capture_no_existing
  run "$(script batch-open-archive-rename-issues.sh)" --only ai_agent
  assert_success
  assert_output --partial '"created":"1"'

  run cat "${GH_STUB_DIR}/calls.log"
  assert_output --partial "issue"
  assert_output --partial "create"
  assert_output --partial "-R"
  assert_output --partial "ycpss91255-docker/ai_agent"
  assert_output --partial "--title"
  assert_output --partial "--body-file"
  # The body-file path lives under our TMPDIR
  assert_output --partial "${TMP_BODIES}/issue-archive-ai_agent.md"
}

@test "--owner overrides default org for create" {
  stub_gh_capture_no_existing
  run "$(script batch-open-archive-rename-issues.sh)" \
    --owner my-org --only sick_noetic
  assert_success
  run cat "${GH_STUB_DIR}/calls.log"
  assert_output --partial "my-org/sick_noetic"
  refute_output --partial "ycpss91255-docker/sick_noetic"
}

# ---- idempotency: skip when title already exists ----

@test "skips create when an issue with the same title already exists" {
  export GH_MATCH="chore: archive ai_agent (out of docker_harness active list)"
  stub_gh_existing_title
  run "$(script batch-open-archive-rename-issues.sh)" --only ai_agent
  assert_success
  assert_output --partial '"body":"issue_skipped"'
  assert_output --partial '"owner_repo":"ycpss91255-docker/ai_agent"'
  assert_output --partial '"skipped":"1"'
  assert_output --partial '"created":"0"'
}

# ---- gh create failure ----

@test "gh create failure counts toward 'failed' and exits 1" {
  stub_gh_create_fails
  run "$(script batch-open-archive-rename-issues.sh)" --only ai_agent
  assert_failure 1
  assert_output --partial '"failed":"1"'
  assert_output --partial "ai_agent"
}
