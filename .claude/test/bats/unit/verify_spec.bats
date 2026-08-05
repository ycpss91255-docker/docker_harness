#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  REPO_DIR="$(mktemp -d)"
  export REPO_DIR
  mkdir -p "${REPO_DIR}/.claude/scripts" \
           "${REPO_DIR}/doc/test" \
           "${REPO_DIR}/.claude/hooks/test/smoke"

  # Default stubs for hard phases — spec runs without docker/just.
  export VERIFY_LINT_CMD='echo "shellcheck pass"'
  export VERIFY_HADOLINT_CMD='echo "hadolint pass"'
  export VERIFY_TEST_CMD='echo "bats pass"'

  cat > "${REPO_DIR}/CLAUDE.md" <<'EOF'
# CLAUDE.md fake

trivial body.
EOF

  cat > "${REPO_DIR}/.claude/scripts/check-claude-md-tree.sh" <<'BASH'
#!/usr/bin/env bash
echo "tree audit pass"
exit 0
BASH
  chmod +x "${REPO_DIR}/.claude/scripts/check-claude-md-tree.sh"

  cat > "${REPO_DIR}/doc/test/TEST.md" <<'EOF'
# Tests

### test/smoke/foo_spec.bats (2)
EOF

  printf '@test "a" { true; }\n@test "b" { true; }\n' \
    > "${REPO_DIR}/.claude/hooks/test/smoke/foo_spec.bats"

  (
    cd "${REPO_DIR}"
    git init -q -b main
    git config user.email t@t
    git config user.name t
    git add -A
    git commit -q -m init
  )
}

teardown() {
  rm -rf "${REPO_DIR}"
}

# ---- arg parsing ----

@test "--help prints usage and exits 0" {
  run "$(script verify.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--dry-run"
  assert_output --partial "--phase"
  assert_output --partial "--continue-on-fail"
}

@test "unknown arg exits 2" {
  run "$(script verify.sh)" --bogus
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
  assert_output --partial '"arg":"--bogus"'
}

@test "--phase needs a name" {
  run "$(script verify.sh)" --phase
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"arg":"--phase"'
  assert_output --partial '"reason":"needs-a-name"'
}

@test "unknown phase name exits 2" {
  run "$(script verify.sh)" --repo-root "${REPO_DIR}" --phase bogus
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
  assert_output --partial '"phase":"bogus"'
}

@test "valid phases listed on bad phase name" {
  run "$(script verify.sh)" --repo-root "${REPO_DIR}" --phase nope
  assert_failure 2
  assert_output --partial '"valid_phases":'
  assert_output --partial "shellcheck"
  assert_output --partial "bats"
}

# ---- dry-run ----

@test "--dry-run prints all phases without executing" {
  run "$(script verify.sh)" --repo-root "${REPO_DIR}" --dry-run
  assert_success
  assert_output --partial "verify (dry-run)"
  assert_output --partial "shellcheck [hard]"
  assert_output --partial "hadolint [hard]"
  assert_output --partial "bats [hard]"
  assert_output --partial "tree-audit"
  assert_output --partial "test-md"
  assert_output --partial "doc-scan"
  assert_output --partial "diff-stats"
  refute_output --partial "shellcheck pass"
}

@test "--dry-run with --phase narrows the plan" {
  run "$(script verify.sh)" --repo-root "${REPO_DIR}" --dry-run --phase test-md
  assert_success
  assert_output --partial "test-md"
  refute_output --partial "shellcheck"
  refute_output --partial "hadolint"
  refute_output --partial "bats"
}

# ---- phase routing ----

@test "single hard phase prints summary table" {
  run "$(script verify.sh)" --repo-root "${REPO_DIR}" --phase shellcheck
  assert_success
  assert_output --partial "shellcheck pass"
  assert_output --partial "## Verify summary"
  assert_output --partial "| shellcheck | pass |"
}

@test "all phases run end-to-end on a clean tree" {
  run "$(script verify.sh)" --repo-root "${REPO_DIR}" --base HEAD
  assert_success
  assert_output --partial "shellcheck pass"
  assert_output --partial "hadolint pass"
  assert_output --partial "bats pass"
  assert_output --partial "tree audit pass"
  assert_output --partial '"body":"lint_pass"'
  assert_output --partial '"kind":"test-md"'
  assert_output --partial "## Verify summary"
}

# ---- TEST.md drift detection ----

@test "TEST.md drift reported when count mismatches" {
  cat > "${REPO_DIR}/doc/test/TEST.md" <<'EOF'
# Tests

### test/smoke/foo_spec.bats (5)
EOF
  run "$(script verify.sh)" --repo-root "${REPO_DIR}" --phase test-md
  assert_failure 1
  assert_output --partial '"body":"drift_detected"'
  assert_output --partial '"claimed":"5"'
  assert_output --partial '"actual":"2"'
  assert_output --partial "| test-md | fail |"
}

@test "TEST.md drift reported for a .claude/test/bats/ heading (refs #265)" {
  mkdir -p "${REPO_DIR}/.claude/test/bats/unit"
  printf '@test "a" { true; }\n' \
    > "${REPO_DIR}/.claude/test/bats/unit/x_spec.bats"
  printf '# Tests\n\n### .claude/test/bats/unit/x_spec.bats (4)\n' \
    > "${REPO_DIR}/doc/test/TEST.md"
  run "$(script verify.sh)" --repo-root "${REPO_DIR}" --phase test-md
  assert_failure 1
  assert_output --partial '"claimed":"4"'
  assert_output --partial '"actual":"1"'
}

@test "TEST.md drift reported when listed file missing" {
  cat > "${REPO_DIR}/doc/test/TEST.md" <<'EOF'
# Tests

### test/smoke/missing_spec.bats (1)
EOF
  run "$(script verify.sh)" --repo-root "${REPO_DIR}" --phase test-md
  assert_failure 1
  assert_output --partial "missing_spec.bats"
  assert_output --partial '"reason":"not-found"'
}

# ---- hard-fail short-circuit ----

@test "hard-phase failure stops later phases by default" {
  VERIFY_LINT_CMD='echo "shellcheck FAIL"; exit 1' \
    run "$(script verify.sh)" --repo-root "${REPO_DIR}" --base HEAD
  assert_failure 1
  assert_output --partial "shellcheck FAIL"
  assert_output --partial "previous hard phase failed"
  assert_output --partial "| shellcheck | fail |"
  assert_output --partial "| hadolint | skipped |"
  assert_output --partial "| bats | skipped |"
}

@test "--continue-on-fail runs later phases despite hard failure" {
  VERIFY_LINT_CMD='echo "shellcheck FAIL"; exit 1' \
    run "$(script verify.sh)" --repo-root "${REPO_DIR}" --base HEAD --continue-on-fail
  assert_failure 1
  assert_output --partial "shellcheck FAIL"
  assert_output --partial "hadolint pass"
  assert_output --partial "bats pass"
  assert_output --partial "| shellcheck | fail |"
  assert_output --partial "| hadolint | pass |"
  assert_output --partial "| bats | pass |"
}

# ---- doc-scan ----

@test "doc-scan flags AI attribution in changed files" {
  printf 'normal line\nCo-Authored-By: Claude something\n' \
    > "${REPO_DIR}/doc/test/notes.txt"
  (
    cd "${REPO_DIR}"
    git add -A
    git commit -q -m "with ai attribution"
  )
  run "$(script verify.sh)" --repo-root "${REPO_DIR}" --phase doc-scan --base HEAD~1
  assert_failure 1
  assert_output --partial '"kind":"ai-attribution"'
  assert_output --partial "notes.txt"
}

@test "doc-scan passes when no AI attribution present" {
  echo "ordinary content" > "${REPO_DIR}/doc/test/notes.txt"
  (
    cd "${REPO_DIR}"
    git add -A
    git commit -q -m "clean"
  )
  run "$(script verify.sh)" --repo-root "${REPO_DIR}" --phase doc-scan --base HEAD~1
  assert_success
  assert_output --partial '"body":"lint_pass"'
  assert_output --partial '"kind":"doc-scan"'
}
