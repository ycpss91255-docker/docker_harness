#!/usr/bin/env bats
# Tests for .claude/scripts/unpublished-worktrees.sh (refs base#1003).
#
# Strategy: build real throwaway git repos under BATS_TEST_TMPDIR and
# PATH-stub `gh`, the same shape prune_merged_worktrees_spec.bats uses. No
# case may reach the network, and none may look at the developer's live
# worktrees -- every fixture root is created per test under
# BATS_TEST_TMPDIR, which bats deletes afterwards.
#
# WHAT THESE CASES DEFEND. The script's predicate is deliberately NOT
# "ahead of origin/main": PRs here land with --squash, so a merged branch's
# commits are never ancestors of main and every landed worktree reads as
# unpublished. Each case below pins one half of the real predicate --
# ahead AND no PR in ANY state, resolved against the worktree's OWN origin,
# and only once the worktree has stopped moving. A spec that asserted only
# "the unpublished branch is reported" would pass on a script that reported
# every branch, which is the failure mode this replaces.
#
# WHY THE SCRIPT IS COPIED INTO A FIXTURE REPO. The script resolves its own
# repo root from ${BASH_SOURCE[0]} to derive the DEFAULT --root, under
# `set -e`, before any argument is used. The test container bind-mounts this
# worktree at /work without the linked-worktree gitdir it points at, so that
# resolution fails there for reasons that have nothing to do with the
# behaviour under test. Copying the shipped file into a real (empty) git
# repo gives it a resolvable location; the CONTENT under test is always the
# working-tree file, read fresh in setup.

load '../lib/test_helper'

setup() {
  # gh stub: answers `gh pr list -R <slug> --state <state> ...` from a
  # fixture file per (repo, state). Two states are kept separately on
  # purpose -- the difference between them is what case (a) is about.
  GH_FIXTURES="${BATS_TEST_TMPDIR}/prs"
  mkdir -p "${GH_FIXTURES}"
  export GH_FIXTURES

  local stub_dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${stub_dir}"
  cat > "${stub_dir}/gh" <<'EOF'
#!/usr/bin/env bash
# gh stub -- print the PR head branches recorded for (-R repo, --state state).
repo=""
state=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -R) repo="$2"; shift 2 ;;
    --state) state="$2"; shift 2 ;;
    *) shift ;;
  esac
done
f="${GH_FIXTURES}/${repo//\//_}.${state}"
[[ -f "${f}" ]] && cat "${f}"
exit 0
EOF
  chmod +x "${stub_dir}/gh"
  export PATH="${stub_dir}:${PATH}"

  # A resolvable home for the script (see the header note).
  local host_repo="${BATS_TEST_TMPDIR}/hostrepo"
  mkdir -p "${host_repo}/.claude/scripts"
  git init -q -b main "${host_repo}"
  cp "$(script unpublished-worktrees.sh)" "${host_repo}/.claude/scripts/"
  SCRIPT="${host_repo}/.claude/scripts/unpublished-worktrees.sh"

  ROOT="${BATS_TEST_TMPDIR}/worktree"
  mkdir -p "${ROOT}"
}

# mk_wt <name> <repo-slug> <branch> [age_minutes] -- a worktree fixture under
# ROOT: a git repo whose origin is <repo-slug>, with origin/main planted at
# the seed commit and one further commit on <branch>, committed
# <age_minutes> ago (default 60, i.e. past the default quiet period).
mk_wt() {
  local name="$1" slug="$2" branch="$3" age_min="${4:-60}"
  local dir="${ROOT}/${name}"
  git init -q -b main "${dir}"
  git -C "${dir}" config user.email "t@t"
  git -C "${dir}" config user.name "t"
  git -C "${dir}" remote add origin "git@github.com:${slug}.git"
  echo seed > "${dir}/seed.txt"
  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m init
  # No network in these specs, so origin/main -- what "ahead" is measured
  # against -- is planted rather than fetched.
  git -C "${dir}" update-ref refs/remotes/origin/main HEAD
  git -C "${dir}" checkout -q -b "${branch}"
  echo work > "${dir}/work.txt"
  git -C "${dir}" add -A
  local when="$(( $(date +%s) - age_min * 60 )) +0000"
  GIT_AUTHOR_DATE="${when}" GIT_COMMITTER_DATE="${when}" \
    git -C "${dir}" commit -q -m "work on ${branch}"
}

# gh_prs <repo-slug> <state> [branch...] -- record what the gh stub answers
# for that repo and that --state.
gh_prs() {
  local slug="$1" state="$2"
  shift 2
  local f="${GH_FIXTURES}/${slug//\//_}.${state}"
  : > "${f}"
  local b
  for b in "$@"; do
    printf '%s\n' "${b}" >> "${f}"
  done
}

@test "--help prints usage and exits 0" {
  run "${SCRIPT}" --help
  assert_success
  assert_output --partial "usage: unpublished-worktrees.sh"
  assert_output --partial "--quiet-minutes"
}

@test "an unknown argument exits 2 and names itself" {
  run "${SCRIPT}" --repo o/r
  assert_failure 2
  assert_output --partial "unknown argument: --repo"
}

@test "a merged, open or closed PR all silence the branch; only no-PR is reported" {
  mk_wt wt-merged owner/repo feat/merged
  mk_wt wt-open   owner/repo feat/open
  mk_wt wt-closed owner/repo feat/closed
  mk_wt wt-nopr   owner/repo feat/nopr
  # --state all sees every PR; --state open sees only the open one. The
  # script must ask the first question, not the second.
  gh_prs owner/repo all  feat/merged feat/open feat/closed
  gh_prs owner/repo open feat/open

  # Precondition: the merged branch really does have commits ahead of main,
  # so the case cannot pass by the branch failing some other test. This is
  # exactly the --squash situation the predicate exists for.
  run git -C "${ROOT}/wt-merged" rev-list --count origin/main..HEAD
  assert_output "1"

  run "${SCRIPT}" --root "${ROOT}"
  assert_success
  assert_output --partial "wt-nopr: 1 commit(s) on feat/nopr (owner/repo), no PR"
  refute_output --partial "feat/merged"
  refute_output --partial "feat/open"
  refute_output --partial "feat/closed"
}

@test "everything published means exit 0 with no output at all" {
  mk_wt wt-merged owner/repo feat/merged
  gh_prs owner/repo all feat/merged

  run "${SCRIPT}" --root "${ROOT}"
  assert_success
  assert_output ""
}

@test "each worktree is answered against its OWN origin, not one shared repo" {
  # One root, two repos, and each branch name exists as a PR in the OTHER
  # repo. A single repo for the whole sweep answers both wrongly, and the
  # direction it fails is silence.
  mk_wt wt-alpha owner/alpha cross/alpha
  mk_wt wt-beta  owner/beta  cross/beta
  gh_prs owner/alpha all cross/beta
  gh_prs owner/beta  all cross/alpha

  run "${SCRIPT}" --root "${ROOT}"
  assert_success
  assert_output --partial "wt-alpha: 1 commit(s) on cross/alpha (owner/alpha), no PR"
  assert_output --partial "wt-beta: 1 commit(s) on cross/beta (owner/beta), no PR"
}

@test "a branch that committed inside the quiet period is not reported" {
  mk_wt wt-fresh owner/repo feat/fresh 0
  gh_prs owner/repo all

  run "${SCRIPT}" --root "${ROOT}"
  assert_success
  assert_output ""
}

@test "--quiet-minutes 0 reports the branch the default window withheld" {
  mk_wt wt-fresh owner/repo feat/fresh 0
  gh_prs owner/repo all

  run "${SCRIPT}" --root "${ROOT}" --quiet-minutes 0
  assert_success
  assert_output --partial "wt-fresh: 1 commit(s) on feat/fresh (owner/repo), no PR"
}

@test "a dirty working tree is not reported, however long it has been idle" {
  mk_wt wt-dirty owner/repo feat/dirty 600
  gh_prs owner/repo all
  echo scratch > "${ROOT}/wt-dirty/uncommitted.txt"

  run "${SCRIPT}" --root "${ROOT}"
  assert_success
  assert_output ""
}

@test "a branch with no commits ahead of origin/main is not reported" {
  mk_wt wt-level owner/repo feat/level
  gh_prs owner/repo all
  # Move origin/main up to the branch tip: nothing is unpublished any more.
  git -C "${ROOT}/wt-level" update-ref refs/remotes/origin/main HEAD

  run "${SCRIPT}" --root "${ROOT}"
  assert_success
  assert_output ""
}

@test "the PR match is exact: fix/9 is not answered by a PR for fix/99" {
  mk_wt wt-nine owner/repo fix/9
  gh_prs owner/repo all fix/99

  run "${SCRIPT}" --root "${ROOT}"
  assert_success
  assert_output --partial "wt-nine: 1 commit(s) on fix/9 (owner/repo), no PR"
}

@test "a worktree on main and a non-repo directory are both skipped" {
  mk_wt wt-nopr owner/repo feat/nopr
  gh_prs owner/repo all
  mk_wt wt-main owner/repo feat/tmp
  git -C "${ROOT}/wt-main" checkout -q main
  mkdir -p "${ROOT}/not-a-repo"

  run "${SCRIPT}" --root "${ROOT}"
  assert_success
  assert_output --partial "wt-nopr:"
  refute_output --partial "wt-main"
  refute_output --partial "not-a-repo"
}

@test "watch mode reports a stalled branch once, not once per interval" {
  mk_wt wt-nopr owner/repo feat/nopr
  gh_prs owner/repo all

  local log="${BATS_TEST_TMPDIR}/watch.log"
  timeout 4 "${SCRIPT}" --root "${ROOT}" --watch 1 > "${log}" 2>&1 || true

  local n
  n="$(grep -c '^wt-nopr:' "${log}" || true)"
  [[ "${n}" -eq 1 ]] || {
    echo "expected wt-nopr reported exactly once over ~4 intervals, got ${n}:"
    cat "${log}"
    return 1
  }
}

@test "watch mode reports a branch that entered the state after it started" {
  mk_wt wt-first owner/repo feat/first
  gh_prs owner/repo all

  local log="${BATS_TEST_TMPDIR}/watch.log"
  timeout 6 "${SCRIPT}" --root "${ROOT}" --watch 1 > "${log}" 2>&1 &
  local watch_pid=$!
  sleep 2
  mk_wt wt-late owner/repo feat/late
  wait "${watch_pid}" || true

  local first late
  first="$(grep -c '^wt-first:' "${log}" || true)"
  late="$(grep -c '^wt-late:' "${log}" || true)"
  [[ "${first}" -eq 1 && "${late}" -eq 1 ]] || {
    echo "expected each branch once (first=${first} late=${late}):"
    cat "${log}"
    return 1
  }
}
