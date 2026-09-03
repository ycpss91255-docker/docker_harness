#!/usr/bin/env bats
#
# Integration: update-stale-pr.sh + a real conflicted git merge + the repo's
# own regenerator (sync-doc-test-counts.sh). Refs #287.
#
# The unit spec (unit/update_stale_pr_spec.bats) stubs git and asserts arg
# handling. These specs do the opposite: real repositories, real merges,
# real conflict markers, and the real generator -- because the behaviour
# under test is what the script does to a CONFLICTED TREE, and a
# hand-written marker string cannot prove that.
#
# Fixture shape (mk_drift_repo): base commit owns two spec files and a
# doc/test catalogue derived from them. The PR branch grows one spec file,
# origin/main grows the OTHER one, and both regenerate the docs. The spec
# files therefore never conflict; the derived figures always do, and their
# two sides differ only in digits -- the "count drift" class of #287.

load '../lib/test_helper'

setup() {
  STUB_DIR="$(mktemp -d)"
  WORKSPACE="$(mktemp -d)"
  mkdir -p "${WORKSPACE}/worktree"
  export PATH="${STUB_DIR}:${PATH}"
  export WORKSPACE_DIR="${WORKSPACE}"
  ORIGIN="${WORKSPACE}/origin.git"
  WT="${WORKSPACE}/worktree/pr-wt"
  GEN=".claude/scripts/sync-doc-test-counts.sh"
  BRANCH="feat/counts"
}

teardown() {
  rm -rf "${STUB_DIR}" "${WORKSPACE}"
  unset WORKSPACE_DIR
}

# stub_gh <head> <base> -- gh shim answering `pr view --json ...`.
stub_gh() {
  cat > "${STUB_DIR}/gh" <<EOF
#!/usr/bin/env bash
printf '%s' '{"headRefName":"$1","baseRefName":"$2","state":"OPEN"}'
EOF
  chmod +x "${STUB_DIR}/gh"
}

# regen -- run the fixture's own copy of the regenerator over the worktree.
regen() {
  "${WT}/${GEN}" "${WT}" >/dev/null
}

# mk_drift_repo -- build ORIGIN + WT such that merging origin/main into
# ${BRANCH} conflicts on nothing but regenerated figures.
#
# Counts: base a=2 b=2 (4); origin/main grows a to 5 (7); the PR branch
# grows b to 6 (8); the merged tree is a=5 b=6 (11), a number NEITHER side
# ever wrote down. That is what makes "recomputed, not chosen" checkable.
mk_drift_repo() {
  git init -q --bare "${ORIGIN}"
  git init -q -b main "${WT}"
  git -C "${WT}" config user.email t@t
  git -C "${WT}" config user.name t
  mkdir -p "${WT}/test/unit" "${WT}/doc/test" "${WT}/.claude/scripts"
  cp "$(script sync-doc-test-counts.sh)" "${WT}/${GEN}"
  write_bats_stanzas "${WT}/test/unit/a_spec.bats" 2
  write_bats_stanzas "${WT}/test/unit/b_spec.bats" 2
  printf '%s\n' \
    '# Unit Tests' '' \
    'Unit level (ISTQB): **0 tests** across 0 specs.' '' \
    '### test/unit/a_spec.bats (0)' '' \
    '### test/unit/b_spec.bats (0)' > "${WT}/doc/test/unit.md"
  printf '%s\n' \
    '# Tests' '' \
    'Grand total (all levels): **0 tests**' '' \
    '| Level | Doc | Tests |' '|-------|-----|-------|' \
    '| Unit | [unit.md](unit.md) | 0 |' > "${WT}/doc/test/TEST.md"
  regen
  git -C "${WT}" add -A
  git -C "${WT}" commit -q -m base
  git -C "${WT}" remote add origin "${ORIGIN}"
  git -C "${WT}" push -q -u origin main

  git -C "${WT}" checkout -q -b "${BRANCH}"
  write_bats_stanzas "${WT}/test/unit/b_spec.bats" 6
  regen
  git -C "${WT}" commit -qam 'branch: grow b'
  git -C "${WT}" push -q -u origin "${BRANCH}"

  git -C "${WT}" checkout -q main
  write_bats_stanzas "${WT}/test/unit/a_spec.bats" 5
  regen
  git -C "${WT}" commit -qam 'main: grow a'
  git -C "${WT}" push -q origin main
  git -C "${WT}" checkout -q "${BRANCH}"
}

@test "count-drift-only merge is auto-resolved, committed and pushed" {
  mk_drift_repo
  stub_gh "${BRANCH}" main

  run "$(script update-stale-pr.sh)" 42 --repo a/b --worktree "${WT}"
  assert_success

  # Nothing left unmerged, and the merge is a real commit with two parents.
  run git -C "${WT}" diff --name-only --diff-filter=U
  assert_output ""
  run git -C "${WT}" rev-list --count --merges HEAD~1..HEAD
  assert_output "1"

  # The figures equal a fresh regenerator run on the merged tree.
  run "${WT}/${GEN}" --check "${WT}"
  assert_success
  # ... and equal 11, which is neither side's number.
  run grep -c '\*\*11 tests\*\*' "${WT}/doc/test/unit.md"
  assert_output "1"

  # The push happened: origin's branch tip is the merge commit.
  local local_tip remote_tip
  local_tip="$(git -C "${WT}" rev-parse HEAD)"
  remote_tip="$(git -C "${ORIGIN}" rev-parse "${BRANCH}")"
  [[ "${local_tip}" == "${remote_tip}" ]] || {
    echo "branch not pushed: ${local_tip} != ${remote_tip}" >&2
    return 1
  }
}

@test "auto-resolution reports the file, hunk count and before/after figures" {
  mk_drift_repo
  stub_gh "${BRANCH}" main

  run "$(script update-stale-pr.sh)" 42 --repo a/b --worktree "${WT}"
  assert_success
  assert_output --partial "doc/test/unit.md"
  assert_output --partial "hunk(s)"
  # Both discarded sides and the recomputed value are shown, so a reader can
  # see 11 was derived rather than picked.
  assert_output --partial "**7 tests**"
  assert_output --partial "**8 tests**"
  assert_output --partial "**11 tests**"
}
