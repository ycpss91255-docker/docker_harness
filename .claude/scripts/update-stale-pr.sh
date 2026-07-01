#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

# update-stale-pr.sh -- one-shot merge-update + NORMAL push for a PR whose
# base branch has moved (mergeStateStatus: BEHIND / CONFLICTING). git
# rebase is disallowed org-wide (refs #221): the branch is refreshed by
# merging the base branch into it and pushing normally -- never rebase,
# never force.
#
# Usage:
#   update-stale-pr.sh <pr> [--repo OWNER/REPO] [--worktree PATH] [--dry-run]
#
# Flow:
#   1. Resolve PR head + base via `gh pr view <pr> --json
#      headRefName,baseRefName`.
#   2. Locate worktree (--worktree wins; else scan
#      ${WORKSPACE_DIR:-pwd}/worktree/* for a checkout on head branch).
#   3. `git -C <wt> fetch origin <base>` then
#      `git -C <wt> merge origin/<base>` into the PR branch.
#   4. On conflict: print conflicted files + suggested next steps,
#      exit 2. No auto-resolution.
#   5. `git -C <wt> push` -- a NORMAL push (no --force, no rebase).
#   6. Print fresh `wait-pr-ci.sh` command to re-arm Monitor.
#
# Exit:
#   0  merged + pushed (or --dry-run preview)
#   1  fetch / merge failed for a non-conflict reason, or push failed
#   2  merge conflict, manual resolution needed
#   3  pre-condition failure (PR not found, worktree not found)
#
# Refs: issue ycpss91255-docker/docker_harness#221 (supersedes the
#       rebase+force-push flow of #87).

set -uo pipefail

_RP_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=lib/log.sh disable=SC1091
source "${_RP_SCRIPT_DIR}/lib/log.sh"

usage() {
  cat >&2 <<'EOF'
Usage: update-stale-pr.sh <pr> [options]

Positional:
  <pr>                  PR number to update.

Options:
  --repo OWNER/REPO     Override gh repo (default: gh resolve from cwd).
  --worktree PATH       Override worktree path (default: scan
                        ${WORKSPACE_DIR:-pwd}/worktree/* for the head
                        branch).
  --dry-run             Print planned actions; no fetch/merge/push.
  -h, --help            Show this help.

Mechanism:
  Merges origin/<base> into the PR branch and pushes NORMALLY. git rebase
  and force-push are disallowed org-wide (refs #221).

Exit codes:
  0  success / dry-run preview
  1  fetch or merge failure (non-conflict), or push failure
  2  merge hit conflicts, manual fix required
  3  pre-condition failure (PR / worktree not found)

Refs: issue #221.
EOF
}

err() { printf '%s\n' "$*" >&2; }

# locate_worktree <head_branch>
# Echoes the absolute path of a worktree whose current branch matches
# <head_branch>. Searches ${WORKSPACE_DIR:-${PWD}}/worktree/*. Empty
# echo if none / ambiguous (caller treats both as failure).
locate_worktree() {
  local head="$1"
  local workspace="${WORKSPACE_DIR:-${PWD}}"
  local root="${workspace}/worktree"
  [[ -d "${root}" ]] || return 0

  local matches=()
  local dir branch
  for dir in "${root}"/*; do
    [[ -d "${dir}/.git" || -f "${dir}/.git" ]] || continue
    branch="$(git -C "${dir}" branch --show-current 2>/dev/null || true)"
    [[ "${branch}" == "${head}" ]] && matches+=("${dir}")
  done

  if (( ${#matches[@]} == 1 )); then
    printf '%s\n' "${matches[0]}"
  fi
}

main() {
  local pr="" repo="" worktree="" dry_run=0
  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --repo)
        [[ $# -ge 2 ]] || { err "missing value for --repo"; return 3; }
        repo="$2"; shift 2 ;;
      --repo=*) repo="${1#--repo=}"; shift ;;
      --worktree)
        [[ $# -ge 2 ]] || { err "missing value for --worktree"; return 3; }
        worktree="$2"; shift 2 ;;
      --worktree=*) worktree="${1#--worktree=}"; shift ;;
      --dry-run) dry_run=1; shift ;;
      -*) err "unknown flag: $1"; return 3 ;;
      *)
        if [[ -z "${pr}" ]]; then pr="$1"; shift
        else err "unexpected arg: $1"; return 3; fi ;;
    esac
  done

  if [[ -z "${pr}" ]]; then
    err "missing <pr>"
    usage
    return 3
  fi
  if ! [[ "${pr}" =~ ^[0-9]+$ ]]; then
    err "invalid <pr>: '${pr}' (expected positive integer)"
    return 3
  fi

  local gh_args=(pr view "${pr}" --json "headRefName,baseRefName,state")
  [[ -n "${repo}" ]] && gh_args+=(--repo "${repo}")

  local pr_json
  pr_json="$(gh "${gh_args[@]}" 2>/dev/null || true)"
  if [[ -z "${pr_json}" ]]; then
    err "PR #${pr}${repo:+ in ${repo}} not found (or gh failed)."
    return 3
  fi

  local head base state
  head="$(printf '%s' "${pr_json}" | jq -r '.headRefName // empty')"
  base="$(printf '%s' "${pr_json}" | jq -r '.baseRefName // empty')"
  state="$(printf '%s' "${pr_json}" | jq -r '.state // empty')"
  if [[ -z "${head}" || -z "${base}" ]]; then
    err "could not parse head/base from PR #${pr}: ${pr_json}"
    return 3
  fi
  if [[ "${state}" != "OPEN" ]]; then
    err "PR #${pr} is ${state}, not OPEN -- nothing to update."
    return 3
  fi

  if [[ -z "${worktree}" ]]; then
    worktree="$(locate_worktree "${head}")"
  fi
  if [[ -z "${worktree}" ]]; then
    err "no worktree found for branch '${head}'."
    err "  Searched: \${WORKSPACE_DIR:-\${PWD}}/worktree/* with branch == '${head}'."
    err "  Pass --worktree <path> to point at it explicitly."
    return 3
  fi
  if [[ ! -d "${worktree}" ]]; then
    err "worktree path does not exist: ${worktree}"
    return 3
  fi

  printf 'updating PR #%s (%s) by merging origin/%s in %s\n' \
    "${pr}" "${head}" "${base}" "${worktree}"

  if (( dry_run )); then
    printf '[dry-run] would: git -C %s fetch origin %s\n' "${worktree}" "${base}"
    printf '[dry-run] would: git -C %s merge origin/%s\n' "${worktree}" "${base}"
    printf '[dry-run] would: git -C %s push\n' "${worktree}"
    return 0
  fi

  if ! git -C "${worktree}" fetch origin "${base}" 2>&1; then
    err "git fetch origin ${base} failed."
    return 1
  fi

  if ! git -C "${worktree}" merge "origin/${base}" 2>&1; then
    if [[ -n "$(git -C "${worktree}" diff --name-only --diff-filter=U 2>/dev/null)" ]]; then
      err ""
      err "merge hit conflicts. Conflicted files:"
      git -C "${worktree}" diff --name-only --diff-filter=U >&2
      err ""
      err "Suggested next steps (manual):"
      err "  1. cd ${worktree}"
      err "  2. Fix each conflict (typical patterns: TEST.md totals, CHANGELOG ordering)."
      err "  3. git add <fixed files>"
      err "  4. git merge --continue   # or: git commit"
      err "  5. git -C ${worktree} push   # NORMAL push, no force"
      err "  6. Re-arm Monitor:"
      err "       .claude/scripts/wait-pr-ci.sh --repo ${repo:-<OWNER/REPO>} --prs ${pr}"
      err ""
      err "Or abort: git -C ${worktree} merge --abort"
      return 2
    fi
    err "git merge origin/${base} failed for a non-conflict reason."
    return 1
  fi

  if ! git -C "${worktree}" push 2>&1; then
    err "git push failed."
    err "  The remote may have moved. Run git -C ${worktree} fetch origin && re-run this script."
    return 1
  fi

  printf '\nPR #%s merge-updated + pushed. Re-arm Monitor:\n' "${pr}"
  printf '  .claude/scripts/wait-pr-ci.sh --repo %s --prs %s\n' \
    "${repo:-<OWNER/REPO>}" "${pr}"
}

main "$@"
