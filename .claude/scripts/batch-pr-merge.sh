#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

# batch-pr-merge.sh — merge-commit a list of PRs across repos.
#
# Pairs together with batch-base-upgrade.sh — that script opens N
# downstream PRs, this one closes them out once their CI is green.
#
# Usage:
#   batch-pr-merge.sh [options] <repo>:<pr> [<repo>:<pr> ...]
#
# `<repo>` is short (e.g. `ai_agent`) — prefixed with the default owner
# `ycpss91255-docker` — or full (`<owner>/<repo>`). Mirrors
# wait-pr-ci-batch.sh so the next-step copy-paste block printed by
# batch-base-upgrade.sh works for both scripts.
#
# Options:
#   --owner <OWNER>  Default owner for short `<repo>` form
#                    (default: ycpss91255-docker)
#   --reset-local    After each successful merge, fetch + checkout
#                    main + reset --hard origin/main in the local repo
#                    checkout. Closes the detached-HEAD aftermath of the
#                    batch-base-upgrade.sh flow (the upgrade script
#                    operates on main checkouts, leaving HEAD detached on
#                    the pre-merge chore branch once GitHub merges
#                    it). Best-effort: missing local checkout / git
#                    failures are logged but do not fail the merge step.
#                    Refs docker_harness#146.
#   --dry-run        Print planned merges and exit without invoking gh
#   -h, --help       Show this help
#
# Behaviour:
#   - Merges each PR with a merge commit (--merge) and --delete-branch (matches the project's
#     branch-protection setup: enforce_admins=true, no force-push, etc.)
#   - On any single-PR failure, prints the gh CLI error and continues
#     with the rest. Prints a summary at the end with merged / failed
#     counts. Non-zero exit if any failure occurred.
#   - PR numbers are validated up-front; a non-numeric PR exits 2 before
#     any gh invocation.
#   - --reset-local resolves each repo's local checkout via the
#     project's standard layout (env/<repo> / app/<repo> / agent/<repo>
#     / <repo> / `base` -> `template/` special case). Missing local
#     checkouts are logged + skipped, not treated as a failure.

set -euo pipefail

_BPM_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=lib/log.sh disable=SC1091
source "${_BPM_SCRIPT_DIR}/lib/log.sh"

readonly DEFAULT_OWNER='ycpss91255-docker'

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

# reset_local_main fetches origin/main, checks out main, and hard-resets
# the local checkout for <owner>/<repo> to origin/main. Best-effort:
# missing checkouts or git failures emit a log line and return 0.
# Workspace layout (docker_harness): env/<repo> / app/<repo> /
# agent/<repo> / <repo> at workspace root; ycpss91255-docker/base lives
# at <workspace>/template/. See CLAUDE.md for the canonical tree.
reset_local_main() {
  local repo="$1"
  local short="${repo##*/}"
  local workspace
  workspace="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
  local -a candidates=(
    "${workspace}/env/${short}"
    "${workspace}/app/${short}"
    "${workspace}/agent/${short}"
    "${workspace}/${short}"
  )
  if [[ "${short}" == "base" ]]; then
    candidates+=("${workspace}/template")
  fi
  local local_path=""
  local c
  for c in "${candidates[@]}"; do
    if [[ -d "${c}/.git" || -f "${c}/.git" ]]; then
      local_path="${c}"
      break
    fi
  done
  if [[ -z "${local_path}" ]]; then
    _log_warn batch-pr-merge repo_skipped repo="${repo}" reason=reset-local-no-checkout
    return 0
  fi
  if ! git -C "${local_path}" fetch origin main --quiet 2>/dev/null; then
    _log_warn batch-pr-merge repo_skipped path="${local_path}" reason=reset-local-fetch-failed
    return 0
  fi
  if ! git -C "${local_path}" checkout main --quiet 2>/dev/null; then
    _log_warn batch-pr-merge repo_skipped path="${local_path}" reason=reset-local-checkout-failed
    return 0
  fi
  if ! git -C "${local_path}" reset --hard origin/main --quiet 2>/dev/null; then
    _log_warn batch-pr-merge repo_skipped path="${local_path}" reason=reset-local-reset-failed
    return 0
  fi
  _log_info batch-pr-merge processing_repo path="${local_path}" kind=reset-local result=at-origin-main
}

main() {
  local dry_run=0
  local reset_local=0
  local owner="${DEFAULT_OWNER}"
  local -a pairs=()

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --dry-run) dry_run=1; shift ;;
      --reset-local) reset_local=1; shift ;;
      --owner) owner="$2"; shift 2 ;;
      --)
        shift
        pairs+=("$@")
        break
        ;;
      *)
        case "$1" in
          *:*) pairs+=("$1"); shift ;;
          *) _log_fatal batch-pr-merge unrecognised_arg arg="${1}"; usage; exit 2 ;;
        esac
        ;;
    esac
  done

  if (( ${#pairs[@]} == 0 )); then
    _log_fatal batch-pr-merge precondition_missing arg="<repo>:<pr>" reason=no-pairs
    usage
    exit 2
  fi

  local -a norm_pairs=()
  local p repo pr
  for p in "${pairs[@]}"; do
    repo="${p%:*}"
    pr="${p##*:}"
    if [[ -z "${repo}" || -z "${pr}" ]]; then
      _log_fatal batch-pr-merge precondition_missing pair="${p}" reason=bad-format
      exit 2
    fi
    if [[ "${pr}" =~ [^0-9] ]]; then
      _log_fatal batch-pr-merge precondition_missing pair="${p}" reason=non-numeric-pr
      exit 2
    fi
    if [[ "${repo}" != */* ]]; then
      repo="${owner}/${repo}"
    fi
    norm_pairs+=("${repo}:${pr}")
  done

  local merged=0
  local failed=0
  local -a failed_pairs=()

  for p in "${norm_pairs[@]}"; do
    repo="${p%:*}"
    pr="${p##*:}"

    if (( dry_run )); then
      _log_info batch-pr-merge dry_run_cmd repo="${repo}" pr="${pr}" action=merge
      continue
    fi

    if gh pr merge "${pr}" -R "${repo}" --merge --delete-branch 2>&1; then
      _log_info batch-pr-merge pr_merged repo="${repo}" pr="${pr}"
      merged=$((merged + 1))
      if (( reset_local )); then
        reset_local_main "${repo}"
      fi
    else
      _log_err batch-pr-merge pr_failed repo="${repo}" pr="${pr}" action=merge
      failed=$((failed + 1))
      failed_pairs+=("${p}")
    fi
  done

  _log_info batch-pr-merge summary merged="${merged}" failed="${failed}"
  if (( failed > 0 )); then
    printf '  failed: %s\n' "${failed_pairs[@]}"
    exit 1
  fi
}

main "$@"
