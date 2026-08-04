#!/usr/bin/env bats
# Tests for .claude/scripts/prune-merged-worktrees.sh (issue #260).
#
# Strategy: build real throwaway git repos + linked worktrees under
# BATS_TEST_TMPDIR and PATH-stub `gh` so the MERGED-PR probe is a constant
# (its correctness is out of scope here). The property under test is that
# every verdict is derived from the WORKTREE PATH, never from the caller's
# cwd, and that --dry-run runs the same resolution as the real run -- so a
# "would remove" preview is always followed by an actual removal.
#
# NEVER point these specs at the developer's live worktrees: every fixture
# lives under BATS_TEST_TMPDIR, which bats deletes per test.

load '../lib/test_helper'

setup() {
  SCRIPT="$(script prune-merged-worktrees.sh)"

  # gh stub: `gh pr list ... --jq '.[0].state'` prints one state token.
  # GH_PR_STATE drives it; default MERGED (the removable case).
  STUB_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${STUB_DIR}"
  cat > "${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${GH_PR_STATE:-MERGED}"
EOF
  chmod +x "${STUB_DIR}/gh"
  export PATH="${STUB_DIR}:${PATH}"

  # Target repo: main checkout on a feature branch (so the "main working
  # tree" rejection cannot be confused with the branch=main skip) plus one
  # linked worktree on another feature branch.
  REPO="${BATS_TEST_TMPDIR}/target"
  mk_repo "${REPO}"
  git -C "${REPO}" checkout -q -b feature/main-checkout
  WT="${BATS_TEST_TMPDIR}/target-260"
  git -C "${REPO}" worktree add -q -b feature/260 "${WT}" feature/main-checkout

  # An unrelated repo to invoke FROM: the workspace-root scenario in #260 --
  # a git repo that legitimately knows nothing about the target's worktrees.
  OTHER="${BATS_TEST_TMPDIR}/other"
  mk_repo "${OTHER}"
}

# mk_repo <dir> -- init a git repo with one commit.
mk_repo() {
  local dir="$1"
  git init -q -b main "${dir}"
  git -C "${dir}" config user.email "t@t"
  git -C "${dir}" config user.name "t"
  echo seed > "${dir}/seed.txt"
  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m init
}

# run_in <cwd> <args...> -- run the script with an explicit cwd. Which repo
# git resolves to is the whole subject of this spec, so no call may inherit
# the ambient cwd by accident.
run_in() {
  local dir="$1"
  shift
  run bash -c 'cd "$1" || exit 1; shift; exec "$@"' bash "${dir}" "${SCRIPT}" "$@"
}

@test "--help prints usage and exits 0" {
  run "${SCRIPT}" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "prune-merged-worktrees.sh"
}

@test "arg validation: missing --repo -> exit 2" {
  run "${SCRIPT}" "${WT}"
  assert_failure 2
  assert_output --partial "--repo"
}

@test "arg validation: no worktree path -> exit 2" {
  run "${SCRIPT}" --repo o/r
  assert_failure 2
  assert_output --partial "at least one worktree path"
}

@test "removes a merged worktree when invoked from an unrelated git repo" {
  run_in "${OTHER}" --repo o/r "${WT}"
  assert_success
  assert_output --partial "RM"
  [[ ! -d "${WT}" ]] || { echo "worktree still on disk: ${WT}"; return 1; }
  run git -C "${REPO}" branch --list feature/260
  assert_output ""
}

@test "--dry-run previews from an unrelated git repo without removing" {
  run_in "${OTHER}" --repo o/r --dry-run "${WT}"
  assert_success
  assert_output --partial "DRY"
  assert_output --partial "would remove"
  [[ -d "${WT}" ]] || { echo "dry-run removed the worktree: ${WT}"; return 1; }
}

@test "verdict is identical from inside and from outside the target repo" {
  run_in "${OTHER}" --repo o/r --dry-run "${WT}"
  assert_success
  local outside="${output}"
  run_in "${REPO}" --repo o/r --dry-run "${WT}"
  assert_success
  [[ "${output}" == "${outside}" ]] || {
    echo "cwd changed the verdict:"
    echo "from ${OTHER}: ${outside}"
    echo "from ${REPO}: ${output}"
    return 1
  }
}

@test "a directory inside a worktree FAILs in dry-run, not just in the real run" {
  mkdir -p "${WT}/sub"
  run_in "${OTHER}" --repo o/r --dry-run "${WT}/sub"
  assert_failure 1
  assert_output --partial "FAIL"
  refute_output --partial "would remove"
}

@test "dry-run and the real run agree on a directory inside a worktree" {
  mkdir -p "${WT}/sub"
  run_in "${OTHER}" --repo o/r --dry-run "${WT}/sub"
  assert_failure 1
  local dry="${output}"
  run_in "${OTHER}" --repo o/r "${WT}/sub"
  assert_failure 1
  [[ "${output}" == "${dry}" ]] || {
    echo "dry-run and real run disagree:"
    echo "dry:  ${dry}"
    echo "real: ${output}"
    return 1
  }
}

@test "the main working tree FAILs in dry-run and in the real run" {
  run_in "${OTHER}" --repo o/r --dry-run "${REPO}"
  assert_failure 1
  assert_output --partial "FAIL"
  assert_output --partial "main working tree"
  run_in "${OTHER}" --repo o/r "${REPO}"
  assert_failure 1
  assert_output --partial "main working tree"
  [[ -d "${REPO}/.git" ]] || { echo "main checkout was damaged: ${REPO}"; return 1; }
}

@test "a path outside any git repository FAILs with a named reason" {
  local plain="${BATS_TEST_TMPDIR}/plain"
  mkdir -p "${plain}"
  run_in "${OTHER}" --repo o/r --dry-run "${plain}"
  assert_failure 1
  assert_output --partial "FAIL"
  assert_output --partial "not inside a git repository"
}

@test "FAIL names the path, the repo consulted and what was expected" {
  mkdir -p "${WT}/sub"
  run_in "${OTHER}" --repo o/r --dry-run "${WT}/sub"
  assert_failure 1
  assert_output --partial "path=${WT}/sub"
  assert_output --partial "repo=${REPO}"
  assert_output --partial "expected"
  refute_output --partial "is not a working tree"
}

@test "summary counts failures alongside removed / skipped" {
  mkdir -p "${WT}/sub"
  run_in "${OTHER}" --repo o/r --dry-run "${WT}/sub"
  assert_failure 1
  assert_output --partial "failed=1"
}

@test "skips a worktree whose PR is not MERGED" {
  export GH_PR_STATE=OPEN
  run_in "${OTHER}" --repo o/r "${WT}"
  assert_success
  assert_output --partial "SKIP"
  assert_output --partial "not merged"
  [[ -d "${WT}" ]] || { echo "unmerged worktree was removed: ${WT}"; return 1; }
}

@test "skips a dirty worktree" {
  echo dirty > "${WT}/dirty.txt"
  run_in "${OTHER}" --repo o/r "${WT}"
  assert_success
  assert_output --partial "dirty working tree"
  [[ -d "${WT}" ]] || { echo "dirty worktree was removed: ${WT}"; return 1; }
}

@test "skips a path that does not exist" {
  run_in "${OTHER}" --repo o/r "${BATS_TEST_TMPDIR}/nope"
  assert_success
  assert_output --partial "no such worktree"
}
