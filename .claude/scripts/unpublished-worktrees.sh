#!/usr/bin/env bash
# log-allow:script -- data-product output (Monitor protocol: one line per branch that needs an operator); stdout IS the event stream this script exists to produce.
# unpublished-worktrees.sh -- name every worktree holding work that will
# reach nobody.
#
# A run that ends with committed, unpushed work exits the same way as one
# that had nothing to do. Nothing distinguishes them from outside, so this
# reads the condition off the worktrees themselves rather than off any
# run's exit (base#1003).
#
# THE PREDICATE. "Commits ahead of origin/main" is not it. PRs here land
# with --squash, so a merged branch's commits are never ancestors of main
# and every landed worktree reads as unpublished -- 47 of them at the time
# this was written, of which 4 were real. A branch holds unpublished work
# when it has commits ahead of main AND no PR exists for it in any state.
# A PR is the published record; an open one is a review in progress, a
# merged one is done, and a closed one was decided. No PR is the only case
# where the work reached nobody.
#
# QUIET PERIOD. A branch under active development satisfies the predicate
# too -- that is what an in-flight implementer looks like. The report is
# therefore gated on the worktree having STOPPED: no commit for
# --quiet-minutes (default 15) and a clean working tree. An unclean tree
# means someone is still typing, whoever they are.
#
# Exits 0 with no output when everything is published. Every line of stdout
# is one branch that needs an operator. Anything that leaves part of the
# sweep UNANSWERED is exit 2 on stderr, never the all-clear: a root that
# does not exist, a default root that cannot be resolved, a repo whose PR
# list gh would not return. "Nothing is unpublished", "I swept nothing" and
# "I could not tell" have to be told apart from outside, or the silence this
# script exists to break is the thing it answers with.
set -euo pipefail

_usage() {
    cat <<'USAGE'
usage: unpublished-worktrees.sh [--root DIR] [--quiet-minutes N]
                                [--watch SECONDS]

  --root           directory holding the worktrees (default: the directory
                   this checkout sits in when it is a linked worktree, and
                   ../worktree relative to the repo root otherwise). A root
                   that does not exist is an error, not an empty sweep. One
                   root holds worktrees of SEVERAL repos, so each is
                   resolved against its own origin -- there is no --repo
                   flag to get wrong.
  --quiet-minutes  a branch must have been idle this long before it is
                   reported (default 15)
  --watch          poll forever at this interval, printing each branch once
                   per transition into the unpublished state; without it the
                   script reports once and exits
USAGE
}

_ROOT=""
_QUIET_MIN=15
_WATCH=0
# Watch mode needs an identity for a report that the printed line does not
# carry; see the watch loop.
_KEYED=0
# Set whenever some part of the sweep could not be answered. Silence is the
# all-clear, so it must not be reachable from a question that went
# unanswered.
_UNANSWERED=0

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --root) _ROOT="${2:?--root needs a value}"; shift 2 ;;
        --quiet-minutes) _QUIET_MIN="${2:?--quiet-minutes needs a value}"; shift 2 ;;
        --watch) _WATCH="${2:?--watch needs a value}"; shift 2 ;;
        -h|--help) _usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "${1}" >&2; _usage >&2; exit 2 ;;
    esac
done

# Only when no --root was given. Resolving this unconditionally kills the
# script under `set -e` while computing a default it was about to discard --
# an explicit --root is precisely the case where the script's own location
# is allowed to be anywhere, including outside a git checkout.
#
# A LINKED worktree already sits in the root being swept
# (<root>/<repo>-<n>), so ../worktree relative to it is one level too deep
# and names a path that does not exist. Every checkout of this repo on the
# machines that run this script is a linked one, so that is the case the
# default has to get right, not the exception.
if [[ -z "${_ROOT}" ]]; then
    _here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    if ! _repo_root="$(git -C "${_here}" rev-parse --show-toplevel 2>/dev/null)"; then
        printf 'no --root given and %s is not inside a git checkout\n' "${_here}" >&2
        exit 2
    fi
    if [[ "$(git -C "${_repo_root}" rev-parse --git-dir)" \
          != "$(git -C "${_repo_root}" rev-parse --git-common-dir)" ]]; then
        _ROOT="$(dirname -- "${_repo_root}")"
    else
        _ROOT="${_repo_root}/../worktree"
    fi
fi

# Silence is this script's all-clear, so a root it cannot read must not be
# able to produce one.
if [[ ! -d "${_ROOT}" ]]; then
    printf 'no such worktree root: %s\n' "${_ROOT}" >&2
    exit 2
fi

# A worktree's repo comes from its OWN origin. One root holds worktrees of
# several repos side by side (base-957 next to docker_harness-290), so a
# single repo for the whole sweep would answer every branch against the
# wrong PR list -- and the direction it fails is silence, since a branch
# not found in the wrong list reads as unpublished only by luck.
_repo_of() {
    git -C "${1}" remote get-url origin 2>/dev/null \
        | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##'
}

# One gh call per REPO per sweep, memoised, not one per worktree.
# --state all is required: an open PR published the work just as much as a
# merged one did, and a closed one recorded the decision not to.
#
# This list is a CACHE, not the answer. gh returns newest-first and --limit
# truncates it silently, so a branch missing from the window may simply have
# an older PR: this org has 614 PRs in one repo, of which a 400 window
# misses 211. The limit is therefore sized to keep the exact per-branch
# query below rare, and correctness does not rest on it.
readonly _PR_WINDOW=1000
declare -A _PR_CACHE=()
declare -A _PR_UNANSWERABLE=()

# _load_prs <repo> -- fill the per-sweep cache for <repo>; non-zero when gh
# would not answer. The cache is written HERE, in the caller's shell, and
# not from inside a command substitution: a function whose result is read
# with $(...) runs in a subshell, so every assignment it makes is discarded
# and "memoised" would mean one gh call per WORKTREE.
_load_prs() {
    local _repo="${1}" _out
    [[ -z "${_PR_UNANSWERABLE[${_repo}]:-}" ]] || return 1
    [[ -z "${_PR_CACHE[${_repo}]+set}" ]] || return 0
    if ! _out="$(gh pr list -R "${_repo}" --state all --limit "${_PR_WINDOW}" \
        --json headRefName --jq '.[].headRefName' 2>&1)"; then
        # A failed query is not "this repo has no PRs". Answering it that
        # way prints every published worktree of the repo as stranded, with
        # the error swallowed.
        _PR_UNANSWERABLE["${_repo}"]=1
        printf 'cannot list PRs for %s: %s\n' "${_repo}" "${_out//$'\n'/ }" >&2
        return 1
    fi
    _PR_CACHE["${_repo}"]="${_out}"
}

# _has_pr <repo> <branch> -- 0 = a PR exists in some state, 1 = none does,
# 2 = the question could not be answered. Only 1 is a report; 2 must not
# become one, because "no PR" and "nobody told me" are different facts.
#
# A miss in the cached window is re-asked exactly, with --head, which the
# window cannot truncate. Misses are rare by construction: they are the
# lines this script prints.
_has_pr() {
    local _repo="${1}" _branch="${2}" _out
    if ! _load_prs "${_repo}"; then
        _UNANSWERED=1
        return 2
    fi
    # An exact-line match: `fix/9` must not be answered by `fix/99`.
    if grep -qxF -- "${_branch}" <<<"${_PR_CACHE[${_repo}]}"; then
        return 0
    fi
    if ! _out="$(gh pr list -R "${_repo}" --head "${_branch}" --state all \
        --limit 1 --json number --jq 'length' 2>&1)"; then
        printf 'cannot list PRs for %s (%s): %s\n' \
            "${_repo}" "${_branch}" "${_out//$'\n'/ }" >&2
        _UNANSWERED=1
        return 2
    fi
    [[ "${_out}" == "0" ]] || return 0
    return 1
}

# _emit <key> <line> -- one report. The key is a stable identity for watch
# mode's dedup and is never part of the data product; see the watch loop.
_emit() {
    if [[ "${_KEYED}" -eq 1 ]]; then
        printf '%s\t%s\n' "${1}" "${2}"
    else
        printf '%s\n' "${2}"
    fi
}

_sweep() {
    local _now _cut _d _b _repo _ahead _last _dirty _pr _report
    _PR_CACHE=()
    _PR_UNANSWERABLE=()
    _now="$(date +%s)"
    _cut=$(( _now - _QUIET_MIN * 60 ))

    for _d in "${_ROOT}"/*/; do
        [[ -e "${_d}/.git" ]] || continue
        _b="$(git -C "${_d}" branch --show-current 2>/dev/null)" || continue
        [[ -n "${_b}" && "${_b}" != "main" ]] || continue

        _repo="$(_repo_of "${_d}")"
        [[ -n "${_repo}" ]] || continue

        # The local guards run FIRST because they are free, and because they
        # decide most worktrees: only what survives them costs a gh call.
        _ahead="$(git -C "${_d}" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
        [[ "${_ahead}" -gt 0 ]] || continue

        _dirty="$(git -C "${_d}" status --porcelain 2>/dev/null | wc -l)"
        [[ "${_dirty}" -eq 0 ]] || continue

        _last="$(git -C "${_d}" log -1 --format=%ct 2>/dev/null || echo "${_now}")"
        [[ "${_last}" -le "${_cut}" ]] || continue

        # Published? Then whatever is on disk has a record.
        _pr=0
        _has_pr "${_repo}" "${_b}" || _pr=$?
        [[ "${_pr}" -eq 1 ]] || continue

        # The key is repo + BRANCH. Worktree directories are recycled --
        # <repo>-<n> is handed to whatever branch takes it next -- so a
        # directory names the first branch to sit there and nothing after.
        _report="$(printf '%s: %s commit(s) on %s (%s), no PR, idle %sm -- %s' \
            "$(basename "${_d}")" "${_ahead}" "${_b}" "${_repo}" \
            "$(( (_now - _last) / 60 ))" \
            "$(git -C "${_d}" log -1 --format=%s)")"
        _emit "${_repo}#${_b}" "${_report}"
    done
}

if [[ "${_WATCH}" -le 0 ]]; then
    _sweep
    [[ "${_UNANSWERED}" -eq 0 ]] || exit 2
    exit 0
fi

# Watch mode reports each branch ONCE PER TRANSITION into the unpublished
# state. Re-reporting the same stalled branch every interval would train the
# reader to ignore the line, which is the same silence this script exists to
# break -- but "once ever" is that silence too, so the seen set is rebuilt
# from each sweep rather than accumulated: a branch that leaves the state
# and enters it again is a new transition and is named again.
_KEYED=1
declare -A _seen=()
declare -A _current=()
while true; do
    _current=()
    while IFS=$'\t' read -r _key _line; do
        [[ -n "${_line}" ]] || continue
        _current["${_key}"]=1
        if [[ -z "${_seen[${_key}]:-}" ]]; then
            printf '%s\n' "${_line}"
        fi
    done < <(_sweep)
    _seen=()
    for _key in "${!_current[@]}"; do
        _seen["${_key}"]=1
    done
    sleep "${_WATCH}"
done
