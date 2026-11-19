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
}

teardown() {
  rm -rf "${TMPDIR}"
}

# commit_in_repo <git commit args...> -- commit with a fixed identity.
commit_in_repo() {
  git -C "${REPO}" -c user.name=t -c user.email=t@example.invalid \
    commit --allow-empty "$@"
}

@test "in a fresh repo the install sets core.hooksPath and the hook then gates commits" {
  run bash -c 'cd "$1" && bash .claude/scripts/install-git-hooks.sh' _ "${REPO}"
  assert_success
  assert_equal "$(git -C "${REPO}" config --get core.hooksPath)" ".claude/githooks"

  local before trailer
  before="$(git -C "${REPO}" rev-parse HEAD)"
  trailer="Co-Authored-By: $(printf '%s' Cla ude) <noreply@$(printf '%s' anth ropic).com>"
  run commit_in_repo -m feat -m "${trailer}"
  assert_failure
  assert_output --partial "AI attribution marker"
  assert_equal "$(git -C "${REPO}" rev-parse HEAD)" "${before}"

  run commit_in_repo -m "feat: a clean subject"
  assert_success
  [[ "$(git -C "${REPO}" rev-parse HEAD)" != "${before}" ]]
}
