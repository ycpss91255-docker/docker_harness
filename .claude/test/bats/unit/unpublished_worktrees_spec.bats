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
# WHERE THE SCRIPT RUNS FROM. Every case that passes --root runs the shipped
# file in place, because an explicit --root means the script never resolves
# its own repo root and its location cannot matter. Only the default-root
# case needs a resolvable location, and it builds the checkout it is about.

load '../lib/test_helper'

setup() {
  # gh stub: answers `gh pr list -R <slug> --state <state> ...` from a
  # fixture file per (repo, state). Two states are kept separately on
  # purpose -- the difference between them is what case (a) is about. The
  # exact per-branch query (`--head <branch>`) is answered from its own
  # fixture, so the truncatable list and the untruncatable query can
  # disagree; that disagreement is what the window case is about.
  # GH_STUB_FAIL makes the call fail the way an auth or rate-limit failure
  # does, which is a different fact from a repo that has no PRs.
  GH_FIXTURES="${BATS_TEST_TMPDIR}/prs"
  mkdir -p "${GH_FIXTURES}"
  export GH_FIXTURES

  local stub_dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${stub_dir}"
  cat > "${stub_dir}/gh" <<'EOF'
#!/usr/bin/env bash
# gh stub -- print the PR head branches recorded for (-R repo, --state state),
# or the count for (-R repo, --head branch).
repo=""
state=""
head=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -R) repo="$2"; shift 2 ;;
    --state) state="$2"; shift 2 ;;
    --head) head="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "${GH_STUB_FAIL:-}" ]]; then
  echo "gh: HTTP 401 Bad credentials" >&2
  exit 1
fi
if [[ -n "${head}" ]]; then
  f="${GH_FIXTURES}/${repo//\//_}.head"
  n=0
  [[ -f "${f}" ]] && n="$(grep -cxF -- "${head}" "${f}" || true)"
  printf '%s\n' "${n}"
  exit 0
fi
f="${GH_FIXTURES}/${repo//\//_}.${state}"
[[ -f "${f}" ]] && cat "${f}"
exit 0
EOF
  chmod +x "${stub_dir}/gh"
  export PATH="${stub_dir}:${PATH}"

  SCRIPT="$(script unpublished-worktrees.sh)"

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
# for that repo and that --state. Anything in --state all is also answerable
# by the exact per-branch query, because the list window is a subset of the
# PRs that exist.
gh_prs() {
  local slug="$1" state="$2"
  shift 2
  local f="${GH_FIXTURES}/${slug//\//_}.${state}"
  : > "${f}"
  local b
  for b in "$@"; do
    printf '%s\n' "${b}" >> "${f}"
  done
  if [[ "${state}" == "all" ]]; then
    local h="${GH_FIXTURES}/${slug//\//_}.head"
    : > "${h}"
    for b in "$@"; do
      printf '%s\n' "${b}" >> "${h}"
    done
  fi
}

# gh_pr_outside_window <repo-slug> <branch> -- a PR that exists but is not in
# the list window. gh returns newest-first and --limit truncates silently, so
# this is what a PR older than the window looks like from inside the script.
gh_pr_outside_window() {
  local slug="$1" branch="$2"
  printf '%s\n' "${branch}" >> "${GH_FIXTURES}/${slug//\//_}.head"
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

@test "a gh failure is an error, not a repo that has no PRs" {
  # One failed call must not answer "no PR" for every worktree of the repo:
  # the branches it would then print are the PUBLISHED ones, and the error
  # that produced them is gone. Same rule as the unswept root -- a question
  # that went unanswered cannot reach the all-clear.
  mk_wt wt-published owner/repo feat/published
  gh_prs owner/repo all feat/published

  export GH_STUB_FAIL=1
  run "${SCRIPT}" --root "${ROOT}"
  assert_failure 2
  assert_output --partial "cannot list PRs for owner/repo"
  refute_output --partial "wt-published"
}

@test "a PR older than the list window is still found, by the exact query" {
  # gh returns newest-first and --limit truncates silently, so a branch whose
  # PR is older than the window is missing from the list with nothing saying
  # so -- 211 of one repo's 614 PRs sit outside a 400 window. The miss is
  # re-asked with --head, which the window cannot truncate.
  mk_wt wt-old owner/repo feat/old
  gh_prs owner/repo all
  gh_pr_outside_window owner/repo feat/old

  run "${SCRIPT}" --root "${ROOT}"
  assert_success
  assert_output ""
}

@test "--root is honoured from a location with no git checkout above it" {
  # The default root is a FALLBACK. Resolving it before --root is read kills
  # the script under `set -e` while computing a value it was about to throw
  # away, and an explicit --root is exactly the case where the script's own
  # location is allowed to be anywhere.
  local nogit="${BATS_TEST_TMPDIR}/nogit"
  mkdir -p "${nogit}"
  cp "$(script unpublished-worktrees.sh)" "${nogit}/"
  mk_wt wt-nopr owner/repo feat/nopr
  gh_prs owner/repo all

  # Precondition: nothing above the copy is a git checkout, so a default-root
  # resolution really would fail here.
  run git -C "${nogit}" rev-parse --show-toplevel
  assert_failure

  run "${nogit}/unpublished-worktrees.sh" --root "${ROOT}"
  assert_success
  assert_output --partial "wt-nopr: 1 commit(s) on feat/nopr (owner/repo), no PR"
}

@test "no --root and no checkout to derive one from is an error, not a crash" {
  local nogit="${BATS_TEST_TMPDIR}/nogit"
  mkdir -p "${nogit}"
  cp "$(script unpublished-worktrees.sh)" "${nogit}/"

  run "${nogit}/unpublished-worktrees.sh"
  assert_failure 2
  assert_output --partial "not inside a git checkout"
}

@test "watch mode names the second branch to occupy a recycled directory" {
  # <repo>-<n> directories are handed on to the next branch by
  # prune-merged-worktrees.sh, so a dedup key that is the DIRECTORY names the
  # first branch to sit there and silences every one after it -- and the
  # direction it fails is silence.
  mk_wt wt-a owner/repo feat/a
  gh_prs owner/repo all

  local log="${BATS_TEST_TMPDIR}/watch.log"
  timeout 6 "${SCRIPT}" --root "${ROOT}" --watch 1 > "${log}" 2>&1 &
  local watch_pid=$!
  sleep 3
  rm -rf "${ROOT}/wt-a"
  mk_wt wt-a owner/repo feat/recycled
  wait "${watch_pid}" || true

  local first recycled
  first="$(grep -c 'on feat/a (' "${log}" || true)"
  recycled="$(grep -c 'on feat/recycled (' "${log}" || true)"
  [[ "${first}" -eq 1 && "${recycled}" -eq 1 ]] || {
    echo "expected each branch once (first=${first} recycled=${recycled}):"
    cat "${log}"
    return 1
  }
}

@test "watch mode reports a branch again after it leaves the state and re-enters" {
  # Once per TRANSITION, not once ever. A branch someone starts typing in
  # again has left the state; when it goes quiet and clean a second time that
  # is a second transition, and a seen-set that only ever grows answers it
  # with the silence this script exists to break.
  mk_wt wt-x owner/repo feat/x
  gh_prs owner/repo all

  local log="${BATS_TEST_TMPDIR}/watch.log"
  timeout 8 "${SCRIPT}" --root "${ROOT}" --watch 1 > "${log}" 2>&1 &
  local watch_pid=$!
  sleep 2
  echo scratch > "${ROOT}/wt-x/uncommitted.txt"
  sleep 3
  rm -f "${ROOT}/wt-x/uncommitted.txt"
  wait "${watch_pid}" || true

  local n
  n="$(grep -c '^wt-x:' "${log}" || true)"
  [[ "${n}" -eq 2 ]] || {
    echo "expected two transitions reported, got ${n}:"
    cat "${log}"
    return 1
  }
}
