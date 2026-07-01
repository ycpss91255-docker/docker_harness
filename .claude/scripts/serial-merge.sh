#!/usr/bin/env bash
# log-allow:script -- emits data-product output (per-PR landing progress + the delegated auto-merge-on-green Monitor stream + a MERGED/FAIL summary line); stdout IS the event stream, like auto-merge-on-green.sh / wait-pr-ci.sh.
#
# serial-merge.sh -- land N same-repo PRs SERIALLY, one at a time.
#
# Under strict branch protection (`strict` = branch must be up to date
# with base before merge), arming auto-merge on N PRs at once is
# O(N^2) in CI runs: each merge advances base, marking every other
# armed PR BEHIND, forcing an update-branch that re-runs CI for all of
# them. Landing PRs one at a time makes it O(N): only the PR at the
# front is in flight, so at most one CI re-run per merge.
#
# Division of labour: this script owns ONLY the ordering. Each PR is
# landed by delegating to the sibling `auto-merge-on-green.sh`, which
# arms GitHub-native auto-merge, polls `mergeStateStatus`, handles
# BEHIND -> update-branch, and merges on green. serial-merge advances
# to the next PR only after the current delegate returns.
#
# Arming model: because we delegate ONE PR at a time and block until it
# finishes, at most ONE PR is ever IN FLIGHT (being armed + polled) at a
# time -- serial-merge never arms a second PR while the first is still
# being driven. (Caveat: a failed PR is deliberately left ARMED for a
# later fix-push, so after a failure a stale-armed PR can coexist with
# the next in-flight one. That stale PR is no longer being update-branch'd
# by anyone, so it does not re-create the O(N^2) churn the #236 gate
# guards against; but it means the #236 gate may still fire on the next
# arm after a failure -- serial-merge should pass SERIAL_MERGE=1 to bypass
# it rather than rely on a strict one-armed invariant.)
#
# Usage:
#   serial-merge.sh [options] <owner/repo> <pr1> <pr2> ...
#
# `<owner/repo>` is a SINGLE repo. A short name (no `/`) is prefixed
# with the default owner `ycpss91255-docker` (mirrors
# batch-pr-merge.sh). Every `<prN>` is landed against that one repo, in
# the given argument order.
#
# Options:
#   --dry-run   Print the planned landing order and exit 0 without
#               invoking auto-merge-on-green.sh or any gh mutation.
#   -h, --help  Show this help
#
# Behaviour:
#   - PRs are landed in argument order; the next PR starts only after
#     the current one's delegate returns (serial, not batched).
#   - Skip-and-continue: if a PR's delegate exits non-zero (CI fail /
#     DIRTY / closed), it is logged and the run continues with the
#     rest. auto-merge-on-green.sh already leaves auto-merge ARMED on a
#     check-failure, so a later fix-push still lands that PR.
#   - Prints a summary line at the end with merged / failed lists.
#     Non-zero exit if any PR failed.
#   - PR numbers are validated up-front; a non-numeric PR exits 2
#     before any delegation.
#
# Exit:
#   0   = all PRs merged
#   1   = one or more PRs failed / were skipped
#   2   = arg error
#
# The delegate path is resolved relative to THIS script's own directory
# (BASH_SOURCE) so serial-merge works from any cwd. Tests override it
# via the SERIAL_MERGE_DELEGATE env var.

set -euo pipefail

_SM_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly DEFAULT_OWNER='ycpss91255-docker'
readonly DELEGATE="${SERIAL_MERGE_DELEGATE:-${_SM_SCRIPT_DIR}/auto-merge-on-green.sh}"

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

err() {
  printf '[serial-merge] ERROR: %s\n' "$*" >&2
}

main() {
  local dry_run=0
  local -a positional=()

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --dry-run) dry_run=1; shift ;;
      --) shift; positional+=("$@"); break ;;
      -*) err "unknown arg: $1"; usage; exit 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done

  if (( ${#positional[@]} == 0 )); then
    err "<owner/repo> is required"
    usage
    exit 2
  fi

  local repo="${positional[0]}"
  local -a prs=("${positional[@]:1}")

  if (( ${#prs[@]} == 0 )); then
    err "at least one <pr> is required"
    usage
    exit 2
  fi

  # Default-owner expansion for a short repo name (mirror batch-pr-merge.sh).
  if [[ "${repo}" != */* ]]; then
    repo="${DEFAULT_OWNER}/${repo}"
  fi

  # Validate PR numbers up-front, before any delegation.
  local pr
  for pr in "${prs[@]}"; do
    [[ "${pr}" =~ ^[0-9]+$ ]] || { err "PR must be a number (got: ${pr})"; exit 2; }
  done

  if (( dry_run )); then
    printf '[serial-merge] plan for %s (%d PR(s), in order): %s\n' \
      "${repo}" "${#prs[@]}" "${prs[*]}"
    local i=1
    for pr in "${prs[@]}"; do
      printf '  %d. PR%s -> auto-merge-on-green.sh --repo %s --pr %s\n' \
        "${i}" "${pr}" "${repo}" "${pr}"
      i=$((i + 1))
    done
    exit 0
  fi

  if [[ ! -x "${DELEGATE}" ]]; then
    err "delegate not found or not executable: ${DELEGATE}"
    exit 2
  fi

  local -a merged=() failed=()
  for pr in "${prs[@]}"; do
    printf '[serial-merge] landing PR%s on %s ...\n' "${pr}" "${repo}"
    # `if` disables set -e for the delegate so a non-zero exit is caught
    # and we skip-and-continue instead of aborting the whole run.
    if "${DELEGATE}" --repo "${repo}" --pr "${pr}"; then
      merged+=("${pr}")
    else
      err "PR${pr} did not land (auto-merge left armed for a fix-push); continuing"
      failed+=("${pr}")
    fi
  done

  printf '[serial-merge] summary: merged=%d failed=%d\n' \
    "${#merged[@]}" "${#failed[@]}"
  if (( ${#merged[@]} > 0 )); then
    printf '  merged: %s\n' "${merged[*]}"
  fi
  if (( ${#failed[@]} > 0 )); then
    printf '  failed: %s\n' "${failed[*]}"
    exit 1
  fi
}

main "$@"
