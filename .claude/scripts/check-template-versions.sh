#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

# check-template-versions.sh — read-only HTTPS fetch of `.base/.version`
# from every downstream repo's main branch. Used during release verification
# to confirm `/batch-base-upgrade <vX.Y.Z>` PRs have all merged.
#
# Replaces the ad-hoc `for repo in ...; do curl raw.githubusercontent.com ...; done`
# pattern, which trips Claude Code's bash AST parser ("Unhandled node type:
# string") because the for-loop body wraps a quoted curl URL.
#
# The repo list comes from lib/roster.tsv, the SAME call batch-base-upgrade.sh
# makes (refs #272). It used to carry its own copy, which had realsense_ros2
# commented out while the upgrader had it active -- so this verifier iterated 2
# repos while the fanout had opened PRs for 3, and reported a clean fanout for
# a repo it never looked at.
#
# Usage:
#   check-template-versions.sh [options]
#
# Options:
#   --only <r1,r2,...>     Limit to listed repos (relative paths, e.g. agent/ai_agent)
#   --skip <r1,r2,...>     Exclude listed repos
#   --expect <vX.Y.Z>      Exit 1 if any repo is not at this version (default: just print)
#   --list-repos           Print the effective repo list and exit (the shared
#                          roster call, for comparing scopes)
#   -h, --help             Show this help
#
# Output: one row per repo, aligned columns:
#   <reponame>             <version-or-MISSING>
#
# Exit:
#   0 = all rows printed (or all match --expect when set)
#   1 = at least one repo did not match --expect
#   2 = arg error, or the selection is empty (a check over no repos is a
#       failed check, not a passed one)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/roster.sh disable=SC1091
source "${SCRIPT_DIR}/lib/roster.sh"

readonly ORG="ycpss91255-docker"

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

err() {
  printf '[check-versions] ERROR: %s\n' "$*" >&2
}

main() {
  local only_csv=""
  local skip_csv=""
  local expect=""
  local list_only=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --only) only_csv="$2"; shift 2 ;;
      --skip) skip_csv="$2"; shift 2 ;;
      --expect) expect="$2"; shift 2 ;;
      --list-repos) list_only=1; shift ;;
      *) err "unknown arg: $1"; usage; exit 2 ;;
    esac
  done

  local repos=()
  if [[ -n "${only_csv}" ]]; then
    IFS=',' read -ra repos <<< "${only_csv}"
  else
    mapfile -t repos < <(roster_fanout_paths active)
  fi

  if [[ -n "${skip_csv}" ]]; then
    local skip_set=" ${skip_csv//,/ } "
    local kept=()
    local r
    for r in "${repos[@]}"; do
      if [[ "${skip_set}" != *" ${r} "* ]]; then
        kept+=("${r}")
      fi
    done
    repos=("${kept[@]}")
  fi

  # A verification pass over nothing is a failed verification, not a passed
  # one: with no rows the mismatch counter below can never move, so --expect
  # would exit 0 having checked no repo at all (refs #272).
  if (( ${#repos[@]} == 0 )); then
    err "no repos selected -- nothing to verify (roster: $(roster_file))"
    exit 2
  fi

  if (( list_only )); then
    printf '%s\n' "${repos[@]}"
    return 0
  fi

  local mismatch=0
  local repo
  for repo in "${repos[@]}"; do
    local reponame="${repo##*/}"
    local url="https://raw.githubusercontent.com/${ORG}/${reponame}/main/.base/.version"
    local ver
    ver="$(curl -fsSL --max-time 10 "${url}" 2>/dev/null || echo "MISSING")"
    printf '%-22s %s\n' "${reponame}" "${ver}"
    if [[ -n "${expect}" && "${ver}" != "${expect}" ]]; then
      mismatch=1
    fi
  done

  if (( mismatch )); then
    err "one or more repos do not match --expect=${expect}"
    exit 1
  fi
}

main "$@"
