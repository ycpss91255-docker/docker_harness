#!/usr/bin/env bats
# Tests for .claude/scripts/serial-merge.sh (issue #235).
#
# Strategy: seam the delegate. serial-merge resolves auto-merge-on-green.sh
# relative to its own dir but honours SERIAL_MERGE_DELEGATE as an override,
# so we point it at a fake delegate that appends its `--repo`/`--pr` to a
# call-log and exits with a code driven by FAIL_PRS (space-separated PR
# numbers that should fail). `gh` is ALSO PATH-stubbed to a logged no-op so
# no real gh mutation can escape. The call-log asserts ordering, the
# default-owner prefix, and skip-and-continue side effects.

load '../lib/test_helper'

setup() {
  SCRIPT="$(script serial-merge.sh)"
  STUB_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${STUB_DIR}"
  CALL_LOG="${BATS_TEST_TMPDIR}/delegate-calls.log"
  : > "${CALL_LOG}"
  export CALL_LOG

  # Fake auto-merge-on-green delegate: log the repo/pr it was asked to
  # land, then exit 1 iff its --pr is listed in FAIL_PRS, else 0.
  FAKE_DELEGATE="${STUB_DIR}/auto-merge-on-green.sh"
  cat > "${FAKE_DELEGATE}" <<'EOF'
#!/usr/bin/env bash
repo="" pr=""
while (( $# > 0 )); do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --pr) pr="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'delegate repo=%s pr=%s\n' "${repo}" "${pr}" >> "${CALL_LOG}"
for f in ${FAIL_PRS:-}; do
  if [[ "${f}" == "${pr}" ]]; then exit 1; fi
done
exit 0
EOF
  chmod +x "${FAKE_DELEGATE}"
  export SERIAL_MERGE_DELEGATE="${FAKE_DELEGATE}"

  # Any real gh call would be a bug -- log it as a no-op so it shows up in
  # the call-log (and never touches the network).
  cat > "${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "${CALL_LOG}"
exit 0
EOF
  chmod +x "${STUB_DIR}/gh"
  export PATH="${STUB_DIR}:${PATH}"
}

@test "--help prints usage and exits 0" {
  run "${SCRIPT}" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "serial-merge.sh"
}

@test "arg validation: missing repo arg -> exit 2" {
  run "${SCRIPT}"
  assert_failure 2
  assert_output --partial "<owner/repo> is required"
}

@test "arg validation: repo but no PR args -> exit 2" {
  run "${SCRIPT}" o/r
  assert_failure 2
  assert_output --partial "at least one <pr> is required"
}

@test "--dry-run prints planned order and makes no delegate/gh call" {
  run "${SCRIPT}" --dry-run o/r 1 2 3
  assert_success
  assert_output --partial "plan for o/r"
  assert_output --partial "PR1 -> auto-merge-on-green.sh --repo o/r --pr 1"
  assert_output --partial "PR3 -> auto-merge-on-green.sh --repo o/r --pr 3"
  # No delegate and no gh call happened: the call-log stays empty.
  run cat "${CALL_LOG}"
  assert_output ""
}

@test "default-owner expansion: short repo foo -> ycpss91255-docker/foo" {
  run "${SCRIPT}" foo 5
  assert_success
  run grep -q "delegate repo=ycpss91255-docker/foo pr=5" "${CALL_LOG}"
  assert_success
}

@test "ordering: PRs are delegated in the given argument order" {
  run "${SCRIPT}" o/r 3 1 2
  assert_success
  run cat "${CALL_LOG}"
  assert_line --index 0 "delegate repo=o/r pr=3"
  assert_line --index 1 "delegate repo=o/r pr=1"
  assert_line --index 2 "delegate repo=o/r pr=2"
}

@test "skip-and-continue: first PR fails, second still lands, exit 1 names failed PR" {
  export FAIL_PRS="10"
  run "${SCRIPT}" o/r 10 11
  assert_failure 1
  assert_output --partial "failed: 10"
  # Mixed run reports BOTH lists: PR 11 landed, PR 10 failed.
  assert_output --partial "merged: 11"
  # The second PR was still delegated despite the first failing.
  run grep -q "delegate repo=o/r pr=11" "${CALL_LOG}"
  assert_success
}

@test "arg validation: non-numeric PR -> exit 2 before any delegation" {
  run "${SCRIPT}" o/r 1 abc 3
  assert_failure 2
  assert_output --partial "PR must be a number"
  # Validation is up-front: nothing was delegated (call-log stays empty).
  run cat "${CALL_LOG}"
  assert_output ""
}

@test "all-success: every delegate exits 0 -> exit 0 with merged summary" {
  run "${SCRIPT}" o/r 1 2 3
  assert_success
  assert_output --partial "merged=3 failed=0"
  assert_output --partial "merged: 1 2 3"
}
