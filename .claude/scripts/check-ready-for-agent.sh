#!/usr/bin/env bash
# log-allow:script -- the verdict IS this script's product; #296 reads the
# missing-part list off stdout, so it must not be wrapped in log records.
#
# check-ready-for-agent.sh -- GATE B of #294: "is this safe to start".
#
# Answers, for one issue, whether it carries the four parts ADR-00000015
# says `ready-for-agent` asserts -- Seams, First slice, Gate, Bound --
# and prints the ones it does not.
#
# Deliberately does NOT look at the issue's labels. ADR-00000015 records
# the two gates as different questions: Gate A
# (.claude/hooks/enforce_ready_for_agent.sh) asks whether the label being
# applied is honest; this one asks whether the work is safe to start, and
# a label already on the issue is not evidence -- the label decaying back
# into decoration is exactly what happened before anything checked it.
#
# The question itself lives in lib/ready-for-agent.sh, shared with Gate A.
# Two copies of the parts list or the heading shape would drift, which is
# the failure this repo keeps repairing.
#
# Usage:
#   check-ready-for-agent.sh [-R <owner/repo>] <issue-number|issue-url>
#
# Options:
#   -R, --repo <owner/repo>  Repo to query (default: gh resolves it from
#                            the working directory). An issue URL carries
#                            its own repo and overrides this.
#   -h, --help               Show this help.
#
# Exit:
#   0  ready -- all four parts present
#   1  not ready -- the missing parts are printed, one per line
#   2  undecidable -- bad arguments, or gh could not be asked. Never
#      report ready for an issue that could not be read.
#
# Refs: #294 (this gate), #296 (its consumer), ADR-00000015.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/gh-command.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/ready-for-agent.sh"

usage() {
  sed -n '/^# Usage:/,/^# Refs:/p' "${BASH_SOURCE[0]}" \
    | grep -v '^# Refs:' | sed 's/^# \{0,1\}//' >&2
}

main() {
  local repo="" target="" ref num url_repo

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; return 0 ;;
      -R|--repo)
        [[ $# -ge 2 ]] || { usage; return 2; }
        repo="$2"
        shift 2
        ;;
      --repo=*) repo="${1#--repo=}"; shift ;;
      -*) usage; return 2 ;;
      *)
        [[ -n "${target}" ]] && { usage; return 2; }
        target="$1"
        shift
        ;;
    esac
  done

  [[ -n "${target}" ]] || { usage; return 2; }

  ref="$(gh_issue_ref_parts "${target}")" || {
    printf 'not an issue number or issue URL: %s\n' "${target}" >&2
    return 2
  }
  num="${ref%% *}"
  url_repo=""
  [[ "${ref}" == *' '* ]] && url_repo="${ref#* }"
  [[ -n "${url_repo}" ]] && repo="${url_repo}"

  local missing status
  missing="$(rfa_check "${num}" "${repo}")"
  status=$?

  case "${status}" in
    0)
      printf 'ready: #%s carries all four parts (%s)\n' \
        "${num}" "$(rfa_headings_hint)"
      return 0
      ;;
    1)
      # The missing-part list goes to stdout because it is the product
      # #296 consumes; the explanation goes to stderr so a caller piping
      # stdout gets the list alone.
      printf 'not ready: #%s is missing the part(s) listed on stdout. Write them back to the issue as a comment under the fixed headings %s, then re-check.\n' \
        "${num}" "$(rfa_headings_hint)" >&2
      printf '%s\n' "${missing}"
      return 1
      ;;
    *)
      printf 'undecidable: could not read #%s (gh unavailable, or the issue does not exist)\n' \
        "${num}" >&2
      return 2
      ;;
  esac
}

main "$@"
