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

@test "a sweep root that does not exist is an error, not the all-clear" {
  # Silence means "everything is published", so a root the script never read
  # must not be able to produce it. Exit 2, the same as a bad argument,
  # because that is what an unreadable root is.
  run "${SCRIPT}" --root "${BATS_TEST_TMPDIR}/no-such-root"
  assert_failure 2
  assert_output --partial "no such worktree root"
}

@test "the default root is read off the main worktree, not the linked one" {
  mk_wt wt-nopr owner/repo feat/nopr
  gh_prs owner/repo all

  # A linked worktree already SITS IN the root being swept, so ../worktree
  # relative to it is one level too deep. Every checkout of this repo on the
  # machines that run the script is a linked one, so the default has to be
  # right there and not only in a main checkout.
  local main_repo="${BATS_TEST_TMPDIR}/mainrepo"
  git init -q -b main "${main_repo}"
  git -C "${main_repo}" config user.email "t@t"
  git -C "${main_repo}" config user.name "t"
  # A worktree of a real repo has an origin; the sweep reads one off every
  # directory it walks, this one included.
  git -C "${main_repo}" remote add origin "git@github.com:owner/linked.git"
  echo seed > "${main_repo}/seed.txt"
  git -C "${main_repo}" add -A
  git -C "${main_repo}" commit -q -m init
  # ROOT is ${BATS_TEST_TMPDIR}/worktree, i.e. the sibling of main_repo the
  # documented default names -- so the two candidate defaults differ, and
  # only one of them finds wt-nopr.
  git -C "${main_repo}" worktree add -q -b side "${ROOT}/wt-linked"
  mkdir -p "${ROOT}/wt-linked/.claude/scripts"
  cp "$(script unpublished-worktrees.sh)" "${ROOT}/wt-linked/.claude/scripts/"

  run "${ROOT}/wt-linked/.claude/scripts/unpublished-worktrees.sh"
  assert_success
  assert_output --partial "wt-nopr: 1 commit(s) on feat/nopr (owner/repo), no PR"
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

@test "a worktree parked on main is skipped even when it is ahead" {
  # Local commits on main satisfy every OTHER guard -- ahead of origin/main,
  # clean, long idle, no PR -- so the branch-name test is the only thing
  # holding the line back. A fixture that merely checks out main is ahead by
  # nothing and would pass with the guard deleted.
  mk_wt wt-nopr owner/repo feat/nopr
  mk_wt wt-main owner/repo feat/tmp
  gh_prs owner/repo all
  git -C "${ROOT}/wt-main" checkout -q main
  echo local > "${ROOT}/wt-main/local.txt"
  git -C "${ROOT}/wt-main" add -A
  local when="$(( $(date +%s) - 3600 )) +0000"
  GIT_AUTHOR_DATE="${when}" GIT_COMMITTER_DATE="${when}" \
    git -C "${ROOT}/wt-main" commit -q -m "local commit on main"

  # Precondition: the guard under test is the only one left to fire.
  run git -C "${ROOT}/wt-main" rev-list --count origin/main..HEAD
  assert_output "1"

  run "${SCRIPT}" --root "${ROOT}"
  assert_success
  assert_output --partial "wt-nopr:"
  refute_output --partial "wt-main"
}

@test "a plain directory is skipped even when a repo encloses the sweep root" {
  # `git -C <dir>` answers from the nearest enclosing repo, so pointing
  # --root inside a checkout gives every plain subdirectory that checkout's
  # branch, origin and ahead-count. Without the .git test each one is
  # reported as a worktree that does not exist. A non-repo directory in a
  # non-repo root is excluded by git failing, not by the guard, so it pins
  # nothing.
  local box="${BATS_TEST_TMPDIR}/box"
  git init -q -b main "${box}"
  git -C "${box}" config user.email "t@t"
  git -C "${box}" config user.name "t"
  git -C "${box}" remote add origin "git@github.com:owner/box.git"
  echo seed > "${box}/seed.txt"
  git -C "${box}" add -A
  git -C "${box}" commit -q -m init
  git -C "${box}" update-ref refs/remotes/origin/main HEAD
  git -C "${box}" checkout -q -b feat/box
  # Committed, so the enclosing tree stays clean and the dirty guard is not
  # the one doing the work.
  mkdir -p "${box}/root/plain"
  echo keep > "${box}/root/plain/keep.txt"
  git -C "${box}" add -A
  local when="$(( $(date +%s) - 3600 )) +0000"
  GIT_AUTHOR_DATE="${when}" GIT_COMMITTER_DATE="${when}" \
    git -C "${box}" commit -q -m "work on feat/box"
  gh_prs owner/box all

  run "${SCRIPT}" --root "${box}/root"
  assert_success
  assert_output ""
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
