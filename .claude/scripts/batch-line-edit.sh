#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

#
# batch-line-edit.sh -- append a line to a file across downstream repos
# if absent (refs #169). The first PRESET over batch-mutation-pr.sh:
# the most common micro-fanout ("add this one line to <file> in every
# repo") that previously spawned a fresh one-shot `batch-add-X-to-Y.sh`
# each time.
#
# It generates an append-line-if-missing mutation and delegates the
# whole fanout (worktree -> mutate -> commit -> push -> PR -> summary)
# to batch-mutation-pr.sh. Idempotent: a repo already carrying the
# exact line is a no-op (the mutation exits 3 -> engine skips it).
#
# Usage:
#   batch-line-edit.sh --file <path> --line "<text>" \
#       (--why-file <path> | --why "<text>") [options]
#
# Options:
#   --file <path>         File to append to, relative to repo root
#                         (required, e.g. .gitignore).
#   --line "<text>"       Exact line to append if absent (required).
#   --why-file <path>     PR body "Why" section (required, or --why).
#   --why "<text>"        Inline alternative to --why-file.
#   --commit-type <t>     fix|feat|chore (default chore); passed through.
#   --pr-title "<title>"  PR title (default: "chore: add line to <file>").
#   --only <r1,r2,...>    Limit to listed repos (passed through).
#   --skip <r1,r2,...>    Exclude listed repos (passed through).
#   --dry-run             Print the plan; skip mutations (passed through).
#   --continue-on-error   Keep going past failures (passed through).
#   -h, --help            Show this help.
#
# Designed to run from the main session (not a subagent).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/log.sh disable=SC1091
source "${SCRIPT_DIR}/lib/log.sh"

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

main() {
  local file="" line="" why_file="" why_text=""
  local commit_type="chore" pr_title=""
  local -a passthrough=()

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --file) file="$2"; shift 2 ;;
      --line) line="$2"; shift 2 ;;
      --why-file) why_file="$2"; shift 2 ;;
      --why) why_text="$2"; shift 2 ;;
      --commit-type) commit_type="$2"; shift 2 ;;
      --pr-title) pr_title="$2"; shift 2 ;;
      --only|--skip) passthrough+=("$1" "$2"); shift 2 ;;
      --dry-run|--continue-on-error) passthrough+=("$1"); shift ;;
      *) _log_fatal batch-line-edit unrecognised_arg arg="${1}"; usage; exit 2 ;;
    esac
  done

  if [[ -z "${file}" ]]; then
    _log_fatal batch-line-edit precondition_missing arg=--file
    exit 2
  fi
  if [[ -z "${line}" ]]; then
    _log_fatal batch-line-edit precondition_missing arg=--line
    exit 2
  fi
  if [[ -z "${why_file}" && -z "${why_text}" ]]; then
    _log_fatal batch-line-edit precondition_missing arg="--why-file|--why"
    exit 2
  fi

  [[ -z "${pr_title}" ]] && pr_title="${commit_type}: add line to ${file}"

  # Generate the append-line-if-missing mutation. It receives the repo
  # path as $1; exit 0 if it appended (changed), 3 if the file already
  # has the exact line (no-op), non-zero on a real error.
  local mut
  mut="$(mktemp)"
  # The single-quoted printf formats below intentionally do NOT expand
  # -- they emit literal shell ($1 / ${repo} / ${f}) into the generated
  # mutation script that runs later in each repo.
  # shellcheck disable=SC2016
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'repo="$1"\n'
    printf 'f="${repo}/%s"\n' "${file}"
    printf '[[ -f "${f}" ]] || exit 1\n'
    printf 'if grep -qxF -- %q "${f}"; then exit 3; fi\n' "${line}"
    printf 'printf "%%s\\n" %q >> "${f}"\n' "${line}"
    printf 'exit 0\n'
  } > "${mut}"
  chmod +x "${mut}"

  local -a engine_args=(
    --mutation "${mut}"
    --pr-title "${pr_title}"
    --commit-type "${commit_type}"
  )
  if [[ -n "${why_file}" ]]; then
    engine_args+=(--why-file "${why_file}")
  else
    engine_args+=(--why "${why_text}")
  fi
  engine_args+=("${passthrough[@]}")

  "${SCRIPT_DIR}/batch-mutation-pr.sh" "${engine_args[@]}"
  local rc=$?
  rm -f "${mut}"
  return "${rc}"
}

main "$@"
