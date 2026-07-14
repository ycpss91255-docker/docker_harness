#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  export GH_STUB_DIR="$(mktemp -d)"
  export PATH="${GH_STUB_DIR}:${PATH}"
}

teardown() {
  rm -rf "${GH_STUB_DIR}"
}

# stub_gh_capture — install a `gh` shim that succeeds and writes its
# argv (one arg per line) to "${GH_STUB_DIR}/calls.log". Each invocation
# appends a separator line `---`.
stub_gh_capture() {
  cat > "${GH_STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
{
  printf '%s\n' "$@"
  printf '%s\n' '---'
} >> "${GH_STUB_DIR}/calls.log"
exit 0
EOF
  chmod +x "${GH_STUB_DIR}/gh"
}

stub_gh_fail() {
  cat > "${GH_STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: simulated failure" >&2
exit 1
EOF
  chmod +x "${GH_STUB_DIR}/gh"
}

@test "--help prints usage and exits 0" {
  run "$(script batch-pr-close.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "<repo>:<pr>"
  assert_output --partial "--reason"
}

@test "missing --reason exits 2" {
  run "$(script batch-pr-close.sh)" ai_agent:1
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"arg":"--reason"'
}

@test "no pairs exits 2" {
  run "$(script batch-pr-close.sh)" --reason "x"
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"reason":"no-pairs"'
}

@test "bad pair (no colon) exits 2" {
  run "$(script batch-pr-close.sh)" --reason "x" not-a-pair
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
}

@test "non-numeric PR exits 2" {
  run "$(script batch-pr-close.sh)" --reason "x" ai_agent:abc
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"reason":"non-numeric-pr"'
}

@test "short repo name is normalized to ycpss91255-docker/<repo>" {
  stub_gh_capture
  run "$(script batch-pr-close.sh)" --reason "superseded" ai_agent:42
  assert_success
  assert_output --partial '"repo":"ycpss91255-docker/ai_agent"'
  assert_output --partial '"pr":"42"'
  run cat "${GH_STUB_DIR}/calls.log"
  assert_output --partial "ycpss91255-docker/ai_agent"
}

@test "full owner/repo form is accepted (no prefix added)" {
  stub_gh_capture
  run "$(script batch-pr-close.sh)" --reason "x" other-org/repo:5
  assert_success
  assert_output --partial '"repo":"other-org/repo"'
  refute_output --partial "ycpss91255-docker/other-org"
}

@test "--owner overrides default for short form" {
  stub_gh_capture
  run "$(script batch-pr-close.sh)" --reason "x" --owner my-org repo-a:7
  assert_success
  assert_output --partial '"repo":"my-org/repo-a"'
}

@test "--dry-run prints planned closes and skips gh invocation" {
  stub_gh_fail
  run "$(script batch-pr-close.sh)" --reason "x" --dry-run ai_agent:1 claude_code:2
  assert_success
  assert_output --partial '"body":"dry_run_cmd"'
  assert_output --partial '"repo":"ycpss91255-docker/ai_agent"'
  assert_output --partial '"repo":"ycpss91255-docker/claude_code"'
  refute_output --partial '"severity_text":"ERROR"'
}

@test "successful close invokes gh pr close with --comment and --delete-branch" {
  stub_gh_capture
  run "$(script batch-pr-close.sh)" --reason "superseded by v0.28.2" ai_agent:1
  assert_success
  run cat "${GH_STUB_DIR}/calls.log"
  assert_output --partial "pr"
  assert_output --partial "close"
  assert_output --partial "--comment"
  assert_output --partial "superseded by v0.28.2"
  assert_output --partial "--delete-branch"
}

@test "--no-delete-branch omits --delete-branch from gh invocation" {
  stub_gh_capture
  run "$(script batch-pr-close.sh)" --reason "x" --no-delete-branch ai_agent:1
  assert_success
  run cat "${GH_STUB_DIR}/calls.log"
  refute_output --partial "--delete-branch"
}

@test "gh failure produces summary and exits 1" {
  stub_gh_fail
  run "$(script batch-pr-close.sh)" --reason "x" ai_agent:1
  assert_failure 1
  assert_output --partial '"body":"pr_failed"'
  assert_output --partial '"body":"summary"'
  assert_output --partial '"closed":"0"'
  assert_output --partial '"failed":"1"'
  assert_output --partial "ai_agent:1"
}

@test "mixed success and failure continues and reports both" {
  cat > "${GH_STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *claude_code*)
    echo "gh: simulated failure" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${GH_STUB_DIR}/gh"
  run "$(script batch-pr-close.sh)" --reason "x" ai_agent:1 claude_code:2 codex_cli:3
  assert_failure 1
  assert_output --partial '"closed":"2"'
  assert_output --partial '"failed":"1"'
  assert_output --partial "claude_code:2"
}

@test "unknown flag exits 2" {
  run "$(script batch-pr-close.sh)" --reason "x" --bogus ai_agent:1
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
}

@test "empty repo in pair exits 2" {
  run "$(script batch-pr-close.sh)" --reason "x" :42
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"reason":"bad-format"'
}

@test "empty PR in pair exits 2" {
  run "$(script batch-pr-close.sh)" --reason "x" ai_agent:
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"reason":"bad-format"'
}
