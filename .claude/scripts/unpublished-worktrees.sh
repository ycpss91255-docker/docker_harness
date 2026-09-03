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
# is one branch that needs an operator.
set -euo pipefail

_usage() {
    cat <<'USAGE'
usage: unpublished-worktrees.sh [--root DIR] [--quiet-minutes N]
                                [--watch SECONDS]

  --root           directory holding the worktrees (default: ../worktree
                   relative to the repo root). One root holds worktrees of
                   SEVERAL repos, so each is resolved against its own
                   origin -- there is no --repo flag to get wrong.
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

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --root) _ROOT="${2:?--root needs a value}"; shift 2 ;;
        --quiet-minutes) _QUIET_MIN="${2:?--quiet-minutes needs a value}"; shift 2 ;;
        --watch) _WATCH="${2:?--watch needs a value}"; shift 2 ;;
        -h|--help) _usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "${1}" >&2; _usage >&2; exit 2 ;;
    esac
done

_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(git -C "${_here}" rev-parse --show-toplevel)"
: "${_ROOT:=${_repo_root}/../worktree}"

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
declare -A _PR_CACHE=()
_pr_branches() {
    local _repo="${1}"
    if [[ -z "${_PR_CACHE[${_repo}]+set}" ]]; then
        _PR_CACHE["${_repo}"]="$(gh pr list -R "${_repo}" --state all --limit 400 \
            --json headRefName --jq '.[].headRefName' 2>/dev/null || true)"
    fi
    printf '%s\n' "${_PR_CACHE[${_repo}]}"
}

_sweep() {
    local _now _cut _d _b _repo _ahead _last _dirty
    _PR_CACHE=()
    _now="$(date +%s)"
    _cut=$(( _now - _QUIET_MIN * 60 ))

    for _d in "${_ROOT}"/*/; do
        [[ -e "${_d}/.git" ]] || continue
        _b="$(git -C "${_d}" branch --show-current 2>/dev/null)" || continue
        [[ -n "${_b}" && "${_b}" != "main" ]] || continue

        _repo="$(_repo_of "${_d}")"
        [[ -n "${_repo}" ]] || continue

        # Published? Then whatever is on disk has a record. An exact-line
        # match: `fix/9` must not be answered by `fix/99`.
        if _pr_branches "${_repo}" | grep -qxF -- "${_b}"; then
            continue
        fi

        _ahead="$(git -C "${_d}" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
        [[ "${_ahead}" -gt 0 ]] || continue

        _dirty="$(git -C "${_d}" status --porcelain 2>/dev/null | wc -l)"
        [[ "${_dirty}" -eq 0 ]] || continue

        _last="$(git -C "${_d}" log -1 --format=%ct 2>/dev/null || echo "${_now}")"
        [[ "${_last}" -le "${_cut}" ]] || continue

        printf '%s: %s commit(s) on %s (%s), no PR, idle %sm -- %s\n' \
            "$(basename "${_d}")" "${_ahead}" "${_b}" "${_repo}" \
            "$(( (_now - _last) / 60 ))" \
            "$(git -C "${_d}" log -1 --format=%s)"
    done
}

if [[ "${_WATCH}" -le 0 ]]; then
    _sweep
    exit 0
fi

# Watch mode reports each branch ONCE per transition. Re-reporting the same
# stalled branch every interval would train the reader to ignore the line,
# which is the same silence this script exists to break.
declare -A _seen=()
while true; do
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] || continue
        _key="${_line%%:*}"
        if [[ -z "${_seen[${_key}]:-}" ]]; then
            _seen["${_key}"]=1
            printf '%s\n' "${_line}"
        fi
    done < <(_sweep)
    sleep "${_WATCH}"
done
