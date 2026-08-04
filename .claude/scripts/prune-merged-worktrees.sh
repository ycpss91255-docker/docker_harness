#!/usr/bin/env bash
# log-allow:script -- human-facing per-worktree progress report is the data product; lib/log.sh structured logging is not applicable to a local maintenance CLI.
#
# prune-merged-worktrees.sh - safely remove git worktrees whose branch has a
# MERGED PR, plus their local branches. One prompt for the whole batch
# (satisfies the batch-via-script gate).
#
# Squash-merge makes the branch tip a non-ancestor of main, so an
# `--is-ancestor` check reports every squash-merged branch as "unmerged".
# The authoritative signal is instead: does the branch have a MERGED PR?
# This script asks `gh` per branch and removes only when the PR is MERGED.
#
# Safety: never touches a worktree that is dirty, whose branch has no MERGED
# PR, that is the main checkout, or that is detached / on `main`. Each such
# case is reported and skipped, never force-removed.
#
# Usage:
#   prune-merged-worktrees.sh --repo <owner>/<repo> [--dry-run] <worktree-path>...
#
# Exit: 0 = ran (some may have been skipped); 2 = arg error.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_die() { printf 'prune-merged-worktrees: %s\n' "$*" >&2; exit 2; }

main() {
  local _repo="" _dry=0
  local -a _paths=()
  while (( $# )); do
    case "$1" in
      --repo) _repo="${2:-}"; shift 2 ;;
      --dry-run) _dry=1; shift ;;
      -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      -*) _die "unknown flag: $1" ;;
      *) _paths+=("$1"); shift ;;
    esac
  done
  [[ -n "${_repo}" ]] || _die "--repo <owner>/<repo> required"
  (( ${#_paths[@]} )) || _die "at least one worktree path required"

  local _removed=0 _skipped=0 _wt _br _head _dirty _prstate
  for _wt in "${_paths[@]}"; do
    if [[ ! -d "${_wt}" ]]; then
      printf 'SKIP  %-32s (no such worktree)\n' "$(basename "${_wt}")"; (( _skipped++ )) || true; continue
    fi
    _br="$(git -C "${_wt}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    _head="$(git -C "${_wt}" rev-parse HEAD 2>/dev/null || echo '?')"
    if [[ "${_br}" == "main" || "${_br}" == "HEAD" || "${_br}" == "?" ]]; then
      printf 'SKIP  %-32s (branch=%s -- refusing main/detached)\n' "$(basename "${_wt}")" "${_br}"; (( _skipped++ )) || true; continue
    fi
    _dirty="$(git -C "${_wt}" status --porcelain 2>/dev/null | head -1)"
    if [[ -n "${_dirty}" ]]; then
      printf 'SKIP  %-32s (dirty working tree)\n' "$(basename "${_wt}")"; (( _skipped++ )) || true; continue
    fi
    _prstate="$(gh pr list --repo "${_repo}" --head "${_br}" --state all \
      --json state --jq '.[0].state' 2>/dev/null || echo '')"
    if [[ "${_prstate}" != "MERGED" ]]; then
      printf 'SKIP  %-32s (branch=%s PR=%s -- not merged)\n' "$(basename "${_wt}")" "${_br}" "${_prstate:-none}"; (( _skipped++ )) || true; continue
    fi
    if (( _dry )); then
      printf 'DRY   %-32s (branch=%s PR=MERGED) would remove\n' "$(basename "${_wt}")" "${_br}"; continue
    fi
    git worktree remove "${_wt}"
    git branch -D "${_br}" >/dev/null 2>&1 || true
    printf 'RM    %-32s (branch=%s PR=MERGED) removed + branch deleted\n' "$(basename "${_wt}")" "${_br}"
    (( _removed++ )) || true
  done
  git worktree prune
  printf '\nremoved=%d skipped=%d\n' "${_removed}" "${_skipped}"
}

main "$@"
