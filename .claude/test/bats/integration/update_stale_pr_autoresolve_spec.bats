#!/usr/bin/env bats
#
# Integration: update-stale-pr.sh + a real conflicted git merge + the repo's
# own doc generator (sync-doc-test-counts.sh). Refs #287.
#
# The unit spec (unit/update_stale_pr_spec.bats) stubs git and asserts arg
# handling. These specs do the opposite: real repositories, real merges,
# real conflict markers, and the real generator -- because the behaviour
# under test is what the script does to a CONFLICTED TREE, and a
# hand-written marker string cannot prove that. Feeding the classifier a
# string would also have hidden the two things the fixtures actually had to
# settle: which lines git decides to put in one hunk, and whether a
# conflicted spec file shows up alongside the catalogs.

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

# regen -- run the fixture's own copy of the generator over the worktree.
regen() {
  "${WT}/${GEN}" "${WT}" >/dev/null
}

# mk_repo <level>... -- build ORIGIN + WT with one catalogue per level, two
# spec files per level, an index, and a base commit whose figures the
# generator wrote. Then grow the tree on both sides of the merge:
#
#   origin/main    grows every level's a_spec (2 -> 5)
#   the PR branch  grows every level's b_spec (2 -> 6)
#
# No spec file is touched on both sides, so no spec file conflicts; every
# derived figure is touched on both sides, so every derived figure does.
# That asymmetry is what makes this a count-drift fixture rather than a
# general merge conflict.
#
# Per level the merged totals are a=5 plus b=6 = 11, a number NEITHER side
# ever wrote down (main saw 7, the branch saw 8). "Recomputed, not chosen"
# is checkable only because 11 appears nowhere in either parent.
#
# Each catalogue also carries one hand-written `Owner:` line, far enough
# from the figures that git keeps it in its own hunk. Untouched it is
# nothing; rewritten on both sides it is the prose conflict of #287.
mk_repo() {
  local levels=("$@") lv
  git init -q --bare "${ORIGIN}"
  git init -q -b main "${WT}"
  git -C "${WT}" config user.email t@t
  git -C "${WT}" config user.name t
  mkdir -p "${WT}/doc/test" "${WT}/.claude/scripts"
  cp "$(script sync-doc-test-counts.sh)" "${WT}/${GEN}"
  {
    printf '# Tests\n\nGrand total (all levels): **0 tests**\n\n'
    printf '| Level | Doc | Tests |\n|-------|-----|-------|\n'
    for lv in "${levels[@]}"; do
      printf '| %s | [%s.md](%s.md) | 0 |\n' "${lv}" "${lv}" "${lv}"
    done
  } > "${WT}/doc/test/TEST.md"
  for lv in "${levels[@]}"; do
    mkdir -p "${WT}/test/${lv}"
    write_bats_stanzas "${WT}/test/${lv}/a_spec.bats" 2
    write_bats_stanzas "${WT}/test/${lv}/b_spec.bats" 2
    {
      printf '# %s Tests\n\n' "${lv}"
      printf '%s level: **0 tests** across 0 specs.\n\n' "${lv}"
      printf '### test/%s/a_spec.bats (0)\n\n' "${lv}"
      printf '### test/%s/b_spec.bats (0)\n\n' "${lv}"
      printf 'Owner: unassigned.\n'
    } > "${WT}/doc/test/${lv}.md"
  done
  regen
  git -C "${WT}" add -A
  git -C "${WT}" commit -q -m base
  git -C "${WT}" remote add origin "${ORIGIN}"
  git -C "${WT}" push -q -u origin main

  git -C "${WT}" checkout -q -b "${BRANCH}"
  grow_specs b_spec 6 "${levels[@]}"
  regen
  git -C "${WT}" commit -qam 'branch: grow every b_spec'
  git -C "${WT}" push -q -u origin "${BRANCH}"

  git -C "${WT}" checkout -q main
  grow_specs a_spec 5 "${levels[@]}"
  regen
  git -C "${WT}" commit -qam 'main: grow every a_spec'
  git -C "${WT}" push -q origin main
  git -C "${WT}" checkout -q "${BRANCH}"
}

# grow_specs <basename> <count> <level>... -- rewrite one spec per level
# with <count> trivial stanzas.
grow_specs() {
  local base="$1" count="$2" lv
  shift 2
  for lv in "$@"; do
    write_bats_stanzas "${WT}/test/${lv}/${base}.bats" "${count}"
  done
}

# edit_owner_line <who> -- rewrite doc/test/unit.md's hand-written `Owner:`
# line in the working tree. Prose, not a figure: the generator passes it
# through untouched, and its two sides do not mask equal.
edit_owner_line() {
  sed -i "s/^Owner: .*/Owner: ${1}./" "${WT}/doc/test/unit.md"
}

# total_regenerated -- sum the `regenerated=N` figures in $output.
total_regenerated() {
  printf '%s\n' "${output}" | grep -o 'regenerated=[0-9]*' | cut -d= -f2 \
    | awk '{ s += $1 } END { print s + 0 }'
}

# assert_nothing_resolved <head-before> <origin-tip-before> -- the merge is
# still in progress exactly as git left it: markers in place in every
# unmerged file, no merge commit, nothing pushed.
assert_nothing_resolved() {
  local head_before="$1" tip_before="$2" f unmerged
  unmerged="$(git -C "${WT}" diff --name-only --diff-filter=U)"
  [[ -n "${unmerged}" ]] || {
    echo "no unmerged paths left -- the merge was resolved" >&2
    return 1
  }
  while IFS= read -r f; do
    grep -q '^<<<<<<<' "${WT}/${f}" || {
      echo "conflict markers gone from ${f} -- it was resolved" >&2
      return 1
    }
  done <<< "${unmerged}"
  [[ "$(git -C "${WT}" rev-parse HEAD)" == "${head_before}" ]] || {
    echo "HEAD moved -- a merge commit was made" >&2
    return 1
  }
  [[ "$(git -C "${ORIGIN}" rev-parse "${BRANCH}")" == "${tip_before}" ]] || {
    echo "origin/${BRANCH} moved -- something was pushed" >&2
    return 1
  }
}

@test "count-drift-only merge is auto-resolved, committed and pushed" {
  mk_repo unit
  stub_gh "${BRANCH}" main

  run "$(script update-stale-pr.sh)" 42 --repo a/b --worktree "${WT}"
  assert_success

  # Nothing left unmerged, and the merge is a real commit with two parents.
  run git -C "${WT}" diff --name-only --diff-filter=U
  assert_output ""
  run git -C "${WT}" rev-list --count --merges HEAD~1..HEAD
  assert_output "1"

  # The figures equal a fresh generator run on the merged tree.
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
  mk_repo unit
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

@test "a numeric conflict outside the generator's output set exits 2" {
  # doc/metrics.md masks equal on both sides -- by the hunk test alone it is
  # indistinguishable from a count-drift hunk. Nothing recomputes it, so
  # taking either side would silently drop a figure someone typed. The
  # question the script has to ask is not "does this look derived" but
  # "does the generator say it writes this file".
  mk_repo unit
  git -C "${WT}" checkout -q "${BRANCH}"
  printf 'Builds this week: 20.\n' > "${WT}/doc/metrics.md"
  git -C "${WT}" add -- doc/metrics.md
  git -C "${WT}" commit -q -m 'branch: metrics'
  git -C "${WT}" push -q origin "${BRANCH}"
  git -C "${WT}" checkout -q main
  printf 'Builds this week: 30.\n' > "${WT}/doc/metrics.md"
  git -C "${WT}" add -- doc/metrics.md
  git -C "${WT}" commit -q -m 'main: metrics'
  git -C "${WT}" push -q origin main
  git -C "${WT}" checkout -q "${BRANCH}"
  stub_gh "${BRANCH}" main

  local head_before tip_before
  head_before="$(git -C "${WT}" rev-parse HEAD)"
  tip_before="$(git -C "${ORIGIN}" rev-parse "${BRANCH}")"

  run "$(script update-stale-pr.sh)" 42 --repo a/b --worktree "${WT}"
  assert_failure 2
  assert_output --partial "doc/metrics.md: owned=no"
  assert_output --partial "not auto-resolvable"
  assert_output --partial "output set"

  assert_nothing_resolved "${head_before}" "${tip_before}"
}

@test "one prose conflict among many count conflicts resolves nothing, exits 2" {
  # Four levels, so the merge carries a count conflict in each level
  # catalogue plus two more in the index -- then one hand-written line in
  # unit.md is rewritten differently on each side. Partial resolution is the
  # tempting bug: every other conflicted file IS auto-resolvable on its own.
  # The rule is all-or-nothing across the whole tree.
  mk_repo unit integration system acceptance
  git -C "${WT}" checkout -q "${BRANCH}"
  edit_owner_line "the branch author"
  git -C "${WT}" commit -qam 'branch: prose'
  git -C "${WT}" push -q origin "${BRANCH}"
  git -C "${WT}" checkout -q main
  edit_owner_line "the main author"
  git -C "${WT}" commit -qam 'main: prose'
  git -C "${WT}" push -q origin main
  git -C "${WT}" checkout -q "${BRANCH}"
  stub_gh "${BRANCH}" main

  local head_before tip_before
  head_before="$(git -C "${WT}" rev-parse HEAD)"
  tip_before="$(git -C "${ORIGIN}" rev-parse "${BRANCH}")"

  run "$(script update-stale-pr.sh)" 42 --repo a/b --worktree "${WT}"
  assert_failure 2
  assert_output --partial "not auto-resolvable"
  assert_output --partial "doc/test/unit.md"
  # The prose hunk was seen as real -- and it was not the only hunk in the
  # tree: the count hunks WERE classified regenerated and still went
  # untouched, which is the all-or-nothing rule and not a fixture in which
  # nothing was resolvable anyway.
  assert_output --partial "real=1"
  local regen_total
  regen_total="$(total_regenerated)"
  (( regen_total >= 5 )) || {
    echo "expected several regenerated hunks beside the prose one, got ${regen_total}" >&2
    echo "${output}" >&2
    return 1
  }

  assert_nothing_resolved "${head_before}" "${tip_before}"
}
