#!/usr/bin/env bats
#
# commit_msg_hook_spec.bats -- the tracked git commit-msg hook
# (.claude/githooks/commit-msg) refuses a commit whose final message carries
# an AI attribution marker (base#1988). Each case runs a real `git commit` in
# a throwaway repo whose core.hooksPath points at the tracked hooks dir.
# Marker strings are built from parts at runtime so this spec never carries
# a literal one.

load '../lib/test_helper'

setup() {
  TMPDIR="$(mktemp -d)"
  REPO="${TMPDIR}/repo"
  git init -q "${REPO}"
  git -C "${REPO}" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m init
  git -C "${REPO}" config core.hooksPath "${PROJECT_ROOT}/.claude/githooks"
  BEFORE="$(git -C "${REPO}" rev-parse HEAD)"
}

teardown() {
  rm -rf "${TMPDIR}"
}

# commit_in_repo <git commit args...> -- commit with a fixed identity.
commit_in_repo() {
  git -C "${REPO}" -c user.name=t -c user.email=t@example.invalid \
    commit --allow-empty "$@"
}

@test "a commit with a co-author trailer naming the AI is refused and HEAD is unchanged" {
  local trailer
  trailer="Co-Authored-By: $(printf '%s' Cla ude) <noreply@$(printf '%s' anth ropic).com>"
  run commit_in_repo -m feat -m "${trailer}"
  assert_failure
  assert_output --partial "AI attribution marker"
  assert_equal "$(git -C "${REPO}" rev-parse HEAD)" "${BEFORE}"
}

@test "a commit with a lower-case 'generated with' line naming the AI tool is refused" {
  local line
  line="$(printf '%s' gener ated) with $(printf '%s' cla ude) code"
  run commit_in_repo -m feat -m "${line}"
  assert_failure
  assert_output --partial "AI attribution marker"
  assert_equal "$(git -C "${REPO}" rev-parse HEAD)" "${BEFORE}"
}

@test "a commit with a trailer using the noreply anthropic address is refused" {
  local trailer
  trailer="Signed-off-by: X <noreply@$(printf '%s' anth ropic).com>"
  run commit_in_repo -m feat -m "${trailer}"
  assert_failure
  assert_output --partial "AI attribution marker"
  assert_equal "$(git -C "${REPO}" rev-parse HEAD)" "${BEFORE}"
}
