#!/usr/bin/env bats
#
# commit_msg_hook_spec.bats -- the tracked git commit-msg hook
# (.claude/githooks/commit-msg) refuses a commit whose final message carries
# an AI attribution marker (base#1988). Each case runs a real `git commit` or
# `git merge` in a throwaway repo whose core.hooksPath points at the tracked
# hooks dir. Marker strings are built from parts at runtime so this spec
# never carries a literal one.

load '../lib/test_helper'

setup() {
  TMPDIR="$(mktemp -d)"
  REPO="${TMPDIR}/repo"
  git init -q "${REPO}"
  git -C "${REPO}" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m init
  git -C "${REPO}" config core.hooksPath "${PROJECT_ROOT}/.claude/githooks"
  BEFORE="$(git -C "${REPO}" rev-parse HEAD)"
  AI="$(printf '%s' Cla ude)"
  ADDR="noreply@$(printf '%s' anth ropic).com"
}

teardown() {
  rm -rf "${TMPDIR}"
}

# commit_in_repo <git commit args...> -- commit with a fixed identity and no
# editor in the environment, so git applies its unedited-message cleanup.
commit_in_repo() {
  env -u GIT_EDITOR git -C "${REPO}" -c user.name=t -c user.email=t@example.invalid \
    commit --allow-empty "$@"
}

# assert_refused <marker> -- the hook named <marker>, told the user how to fix
# it, and HEAD did not move.
assert_refused() {
  assert_failure
  assert_output --partial "commit message carries an AI attribution marker: '$1'. Remove it and commit again."
  assert_equal "$(git -C "${REPO}" rev-parse HEAD)" "${BEFORE}"
}

@test "a -m co-author trailer naming the AI is refused naming the marker, and HEAD is unchanged" {
  run commit_in_repo -m feat -m "Co-Authored-By: ${AI} <bot@example.invalid>"
  assert_refused "Co-Authored-By: ${AI}"
}

@test "a clean subject naming the .claude/hooks path is accepted" {
  run commit_in_repo -m "feat: add the .claude/hooks guard"
  assert_success
  [[ "$(git -C "${REPO}" rev-parse HEAD)" != "${BEFORE}" ]]
}

@test "a lower-case 'generated with' line in a -F message file is refused naming the marker" {
  local line
  line="$(printf '%s' gener ated) with $(printf '%s' cla ude) code"
  printf 'feat\n\n%s\n' "${line}" > "${TMPDIR}/msg"
  run commit_in_repo -F "${TMPDIR}/msg"
  assert_refused "${line}"
}

@test "a trailer whose value is the bare upper-case noreply anthropic address is refused" {
  local upper
  upper="$(printf '%s' "${ADDR}" | tr '[:lower:]' '[:upper:]')"
  run commit_in_repo -m feat -m "Signed-off-by: ${upper}"
  assert_refused "Signed-off-by: ${upper}"
}

@test "a marker only in a '#' comment line of an edited message is accepted" {
  # The editor appends the marker as a comment line; git's default cleanup
  # for an edited message strips it, so the commit carries no marker.
  local trailer="Co-Authored-By: ${AI} <${ADDR}>"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "# %s" >> "$1"\n' "${trailer}" \
    > "${TMPDIR}/editor"
  chmod +x "${TMPDIR}/editor"
  GIT_EDITOR="${TMPDIR}/editor" run git -C "${REPO}" -c user.name=t \
    -c user.email=t@example.invalid commit --allow-empty -e -m feat
  assert_success
  [[ "$(git -C "${REPO}" rev-parse HEAD)" != "${BEFORE}" ]]
  run git -C "${REPO}" log -1 --format=%B
  refute_output --partial "noreply@"
}

@test "a '#' heading in an unedited -F message, which git keeps, is refused when it carries a marker" {
  printf 'feat\n\n# Co-Authored-By: %s\n' "${AI}" > "${TMPDIR}/msg"
  run commit_in_repo -F "${TMPDIR}/msg"
  assert_refused "Co-Authored-By: ${AI}"
}

@test "a long message with a marker near the top is refused" {
  {
    printf 'feat\n\nCo-Authored-By: %s\n' "${AI}"
    seq 1 200000
  } > "${TMPDIR}/msg"
  run commit_in_repo -F "${TMPDIR}/msg"
  assert_refused "Co-Authored-By: ${AI}"
}

@test "a git merge --no-ff -m carrying a marker is refused and HEAD is unchanged" {
  local main
  main="$(git -C "${REPO}" branch --show-current)"
  git -C "${REPO}" checkout -q -b side
  git -C "${REPO}" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m side
  git -C "${REPO}" checkout -q "${main}"
  run env -u GIT_EDITOR git -C "${REPO}" -c user.name=t -c user.email=t@example.invalid \
    merge --no-ff -m "merge side" -m "Co-Authored-By: ${AI} <bot@example.invalid>" side
  assert_refused "Co-Authored-By: ${AI}"
}
