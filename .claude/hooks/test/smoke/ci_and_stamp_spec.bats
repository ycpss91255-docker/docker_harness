#!/usr/bin/env bats

# Covers .claude/scripts/ci-and-stamp.sh (refs #208) — runs the repo's
# full CI mirror and, on green, writes the local-ci-pass marker that
# enforce_local_full_ci_before_pr.sh checks. Detection is by marker
# file (.claude/test/Makefile -> docker_harness `make check`;
# justfile.ci -> base `just -f justfile.ci test|lint`; root justfile ->
# downstream `./build.sh test`; none -> no stamp, fail-open notice).
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
