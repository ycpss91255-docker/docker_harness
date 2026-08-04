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
# cwd-independent: the repo that each `git worktree` / `git branch` call is
# driven from is derived from the worktree path itself
# (`rev-parse --git-common-dir`), never inherited from the caller's cwd. A
# batch maintenance CLI runs from wherever the operator happens to stand --
# most often the workspace root, which is itself a git repo that knows nothing
# about the target repo's worktrees.
#
# `--dry-run` performs exactly the same resolution and validation as the real
# run and short-circuits only the mutating calls, so its verdicts ARE the real
# run's verdicts: whatever it reports as removable is removable.
#
# Safety: never touches a worktree that is dirty, whose branch has no MERGED
# PR, that is the main working tree, or that is detached / on `main`. Each
# such case is reported and skipped, never force-removed.
#
# Usage:
#   prune-merged-worktrees.sh --repo <owner>/<repo> [--dry-run] <worktree-path>...
#
# Exit: 0 = ran (some may have been skipped); 1 = at least one path could not
# be resolved to a removable worktree; 2 = arg error.
#
# Style: Google Shell Style Guide.

set -euo pipefail

_die() { printf 'prune-merged-worktrees: %s\n' "$*" >&2; exit 2; }

# _git_path <worktree-path> <rev-parse-flag> -- print an absolute git path
# (--git-dir / --git-common-dir / --show-toplevel) for <worktree-path>.
_git_path() {
  git -C "$1" rev-parse --path-format=absolute "$2" 2>/dev/null
}

# _resolve_repo <worktree-path> -- validate that the path is the root of a
# LINKED worktree and set _REPO to the working tree whose git must drive the
# removal (`git -C "${_REPO}" worktree remove <path>`). Returns non-zero on
# failure with the reason in _REASON; _REPO is still set whenever the path
# resolved to a repository at all, so an error can name what git consulted.
#
# The real run needs this resolution, so --dry-run performs it too: a preview
# that cannot be trusted is worse than no preview at all.
_resolve_repo() {
  local _wt="$1" _common _gitdir _top _abs
  _REPO="" _REASON=""
  if ! _common="$(_git_path "${_wt}" --git-common-dir)" || [[ -z "${_common}" ]]; then
    _REASON="not inside a git repository -- expected the root of a linked git worktree"
    return 1
  fi
  # The shared git dir is <main-working-tree>/.git in a normal clone; a bare or
  # separate git dir is left as-is (git drives worktree ops from it just fine).
  _REPO="${_common%/.git}"
  _gitdir="$(_git_path "${_wt}" --git-dir)"
  _top="$(_git_path "${_wt}" --show-toplevel)"
  _abs="$(readlink -f -- "${_wt}")"
  if [[ "${_top}" != "${_abs}" ]]; then
    _REASON="not a worktree root (it sits inside worktree ${_top}) -- expected the root of a linked git worktree"
    return 1
  fi
  if [[ "${_gitdir}" == "${_common}" ]]; then
    _REASON="is the main working tree -- expected a linked git worktree"
    return 1
  fi
  return 0
}

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

  # Newline-delimited set of the repos resolved so far; each is pruned once,
  # at the end, instead of pruning whatever repo the cwd happened to be in.
  local _seen_repos=$'\n'
  local _removed=0 _skipped=0 _failed=0 _wt _br _head _dirty _prstate
  for _wt in "${_paths[@]}"; do
    if [[ ! -d "${_wt}" ]]; then
      printf 'SKIP  %-32s (no such worktree)\n' "$(basename "${_wt}")"; (( _skipped++ )) || true; continue
    fi
    if ! _resolve_repo "${_wt}"; then
      printf 'FAIL  %-32s (path=%s repo=%s) %s\n' \
        "$(basename "${_wt}")" "${_wt}" "${_REPO:-<unresolved>}" "${_REASON}"
      (( _failed++ )) || true; continue
    fi
    if [[ "${_seen_repos}" != *$'\n'"${_REPO}"$'\n'* ]]; then
      _seen_repos+="${_REPO}"$'\n'
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
    git -C "${_REPO}" worktree remove "${_wt}"
    git -C "${_REPO}" branch -D "${_br}" >/dev/null 2>&1 || true
    printf 'RM    %-32s (branch=%s PR=MERGED) removed + branch deleted\n' "$(basename "${_wt}")" "${_br}"
    (( _removed++ )) || true
  done

  # Prune is mutating, so the dry-run asks git for its plan instead.
  local -a _prune_flags=()
  if (( _dry )); then
    _prune_flags=(--dry-run)
  fi
  local _seen_repo
  while IFS= read -r _seen_repo; do
    [[ -n "${_seen_repo}" ]] || continue
    git -C "${_seen_repo}" worktree prune "${_prune_flags[@]+"${_prune_flags[@]}"}"
  done <<< "${_seen_repos}"

  printf '\nremoved=%d skipped=%d failed=%d\n' "${_removed}" "${_skipped}" "${_failed}"
  (( _failed == 0 )) || exit 1
}

main "$@"
