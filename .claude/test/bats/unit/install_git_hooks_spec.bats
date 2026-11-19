#!/usr/bin/env bats
#
# install_git_hooks_spec.bats -- .claude/scripts/install-git-hooks.sh points
# a harness checkout's core.hooksPath at the tracked .claude/githooks dir so
# the commit-msg hook runs on every commit (base#1988). Each case copies the
# harness pieces the hook needs into a fresh throwaway repo and runs the
# install from inside it. Marker strings are built from parts at runtime so
# this spec never carries a literal one.

load '../lib/test_helper'

setup() {
  TMPDIR="$(mktemp -d)"
  REPO="${TMPDIR}/repo"
  git init -q "${REPO}"
  mkdir -p "${REPO}/.claude/scripts/lib"
  cp -R "${PROJECT_ROOT}/.claude/githooks" "${REPO}/.claude/githooks"
  cp "${PROJECT_ROOT}/.claude/scripts/lib/attribution_marker.sh" \
    "${REPO}/.claude/scripts/lib/"
  cp "${PROJECT_ROOT}/.claude/scripts/install-git-hooks.sh" \
    "${REPO}/.claude/scripts/" 2>/dev/null || true
  git -C "${REPO}" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m init
  HOOKS="${REPO}/.git/hooks"
  TRAILER="Co-Authored-By: $(printf '%s' Cla ude) <bot@example.invalid>"
}

teardown() {
  rm -rf "${TMPDIR}"
}

# commit_in_repo <git commit args...> -- commit with a fixed identity.
commit_in_repo() {
  env -u GIT_EDITOR git -C "${REPO}" -c user.name=t -c user.email=t@example.invalid \
    commit --allow-empty "$@"
}

install_hooks() {
  run bash -c 'cd "$1" && bash .claude/scripts/install-git-hooks.sh' _ "${REPO}"
}

@test "in a fresh repo the install sets core.hooksPath and the hook then gates commits" {
  install_hooks
  assert_success
  assert_equal "$(git -C "${REPO}" config --get core.hooksPath)" ".claude/githooks"

  local before
  before="$(git -C "${REPO}" rev-parse HEAD)"
  run commit_in_repo -m feat -m "${TRAILER}"
  assert_failure
  assert_output --partial "AI attribution marker"
  assert_equal "$(git -C "${REPO}" rev-parse HEAD)" "${before}"

  run commit_in_repo -m "feat: a clean subject"
  assert_success
  [[ "$(git -C "${REPO}" rev-parse HEAD)" != "${before}" ]]
}

@test "an existing commit-msg hook is left running, and the advertised chain line adds the check to it" {
  printf '#!/bin/sh\nif grep -q WIP "$1"; then echo "existing hook: no WIP" >&2; exit 1; fi\n' \
    > "${HOOKS}/commit-msg"
  chmod +x "${HOOKS}/commit-msg"

  install_hooks
  assert_success
  # Follow the notice: append the line it prints after its last ': '.
  printf '%s\n' "${output##*: }" >> "${HOOKS}/commit-msg"
  run git -C "${REPO}" config --get core.hooksPath
  assert_failure

  run commit_in_repo -m "WIP: x"
  assert_failure
  assert_output --partial "existing hook: no WIP"
  run commit_in_repo -m feat -m "${TRAILER}"
  assert_failure
  assert_output --partial "AI attribution marker"
  run commit_in_repo -m "feat: a clean subject"
  assert_success
}

@test "an existing pre-commit hook with no commit-msg hook is left running and the notice is printed" {
  printf '#!/bin/sh\ntouch "%s/pre-commit-ran"\n' "${TMPDIR}" > "${HOOKS}/pre-commit"
  chmod +x "${HOOKS}/pre-commit"

  install_hooks
  assert_success
  assert_output --partial ".claude/githooks/commit-msg"
  run git -C "${REPO}" config --get core.hooksPath
  assert_failure

  run commit_in_repo -m "feat: a clean subject"
  assert_success
  [[ -f "${TMPDIR}/pre-commit-ran" ]]
}
