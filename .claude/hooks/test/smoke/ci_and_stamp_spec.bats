#!/usr/bin/env bats

# Covers .claude/scripts/ci-and-stamp.sh (refs #208) — runs the repo's
# full CI mirror and, on green, writes the local-ci-pass marker that
# enforce_local_full_ci_before_pr.sh checks. Detection is by marker
# file (.claude/test/Makefile -> docker_harness `make check`;
# root justfile + .base/ subtree -> downstream `just build test`;
# root justfile, no .base/ -> base `just test` + `just test lint`;
# none -> no stamp, fail-open notice). Detection order matters: the
# downstream `.base/` check precedes the base check (both have a root
# justfile; the .base/ subtree is what a consumer repo vendors). Refs #220.
#
# The actual CI runner (make / just / ./build.sh) is stubbed via a
# PATH shim that exits ${STUB_RC:-0}, so no real docker / make / just
# is needed.

load '../lib/test_helper'

setup() {
  STUB_DIR="$(mktemp -d)"
  REPO="$(mktemp -d)"
  git -C "${REPO}" init -q -b main
  git -C "${REPO}" config user.email t@t
  git -C "${REPO}" config user.name t
  echo x > "${REPO}/f"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m init
}

teardown() {
  rm -rf "${STUB_DIR}" "${REPO}"
}

# stub_cmd <name> — install a PATH shim that exits ${STUB_RC:-0}.
stub_cmd() {
  printf '#!/usr/bin/env bash\nexit ${STUB_RC:-0}\n' > "${STUB_DIR}/$1"
  chmod +x "${STUB_DIR}/$1"
}

marker() { echo "${REPO}/.claude/state/local-ci-pass/$(git -C "${REPO}" rev-parse HEAD).ok"; }

@test "docker_harness-style (.claude/test/Makefile) green -> stamps marker" {
  mkdir -p "${REPO}/.claude/test"
  echo "check:" > "${REPO}/.claude/test/Makefile"
  stub_cmd make
  PATH="${STUB_DIR}:${PATH}" STUB_RC=0 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success
  [[ -f "$(marker)" ]] || { echo "marker not written: $(marker)"; return 1; }
}

@test "CI command non-zero -> NO marker, propagates failure" {
  mkdir -p "${REPO}/.claude/test"
  echo "check:" > "${REPO}/.claude/test/Makefile"
  stub_cmd make
  PATH="${STUB_DIR}:${PATH}" STUB_RC=1 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_failure
  [[ ! -f "$(marker)" ]] || { echo "marker should NOT exist on CI failure"; return 1; }
}

@test "base-style (root justfile, no .base) green -> runs just test + stamps" {
  echo 'test:' > "${REPO}/justfile"
  stub_cmd just
  PATH="${STUB_DIR}:${PATH}" STUB_RC=0 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success
  [[ -f "$(marker)" ]] || { echo "marker not written for base-style"; return 1; }
}

@test "downstream (root justfile + .base subtree) green -> runs just build test + stamps" {
  echo 'build *args:' > "${REPO}/justfile"
  mkdir -p "${REPO}/.base"
  stub_cmd just
  PATH="${STUB_DIR}:${PATH}" STUB_RC=0 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success
  [[ -f "$(marker)" ]] || { echo "marker not written for downstream"; return 1; }
}

@test "no CI mechanism -> no stamp, exit 0, notice" {
  PATH="${STUB_DIR}:${PATH}" run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success
  [[ ! -f "$(marker)" ]] || { echo "should not stamp a no-CI repo"; return 1; }
  assert_output --partial "no_ci_mechanism"
}

@test "marker filename is the exact HEAD sha" {
  mkdir -p "${REPO}/.claude/test"
  echo "check:" > "${REPO}/.claude/test/Makefile"
  stub_cmd make
  local sha; sha="$(git -C "${REPO}" rev-parse HEAD)"
  PATH="${STUB_DIR}:${PATH}" STUB_RC=0 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success
  [[ -f "${REPO}/.claude/state/local-ci-pass/${sha}.ok" ]] || { echo "marker not keyed by HEAD sha"; return 1; }
}
