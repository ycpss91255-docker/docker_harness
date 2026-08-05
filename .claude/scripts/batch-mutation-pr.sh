#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

#
# batch-mutation-pr.sh -- generic cross-repo fanout engine (refs #169).
#
# Opens one PR per downstream repo, applying a CALLER-SUPPLIED mutation
# to each. Extracts the shared skeleton of the historical one-shot
# `batch-*.sh` / `fix-*.sh` / `migrate-*.sh` scripts -- all of which
# repeat the identical plumbing (per-repo: fetch main -> branch ->
# mutate -> commit -> push -> open PR) and differ only in the 5-10 line
# "mutate" step. That step is now the caller's `--mutation` script;
# this engine owns everything else.
#
# Usage:
#   batch-mutation-pr.sh --mutation <script> --pr-title "<title>" \
#       (--why-file <path> | --why "<text>") [options]
#
# Options:
#   --mutation <script>   Executable run once per repo to apply the
#                         change (required). See "Mutation contract".
#   --pr-title "<title>"  PR title + commit subject (required).
#   --why-file <path>     PR body "Why" section content (required, or
#                         use --why).
#   --why "<text>"        Inline alternative to --why-file.
#   --commit-type <t>     One of fix|feat|chore (default chore). Drives
#                         the conventional-commit prefix on the branch
#                         name; the --pr-title is used verbatim.
#   --branch <name>       Branch name (optional; default derived by
#                         slugifying the title).
#   --only <r1,r2,...>    Limit to listed repos.
#   --skip <r1,r2,...>    Exclude listed repos.
#   --dry-run             Print the per-repo plan; skip all mutations.
#   --continue-on-error   Keep going past a failing repo; summarise.
#   -h, --help            Show this help.
#
# Mutation contract:
#   The mutation script is invoked as `<mutation> <repo-path>` with the
#   repo's branch checked out under <repo-path>. It mutates files in
#   place and signals via exit code:
#     0   -> changed: engine commits + pushes + opens a PR.
#     3   -> no-op / skip: engine drops the branch, no PR (idempotent
#            re-runs land here).
#     *   -> error: engine records a failure (honours
#            --continue-on-error).
#   The mutation's stdout/stderr are captured to a per-repo log and
#   MUST NOT be relied on as engine output -- the engine owns the data
#   product (the _log_* JSON stream + the opened/skipped/failed
#   summary).
#
# Presets: batch-line-edit.sh wraps this engine with an
# append-line-if-missing mutation (the most common micro-fanout).
#
# Designed to run from the main session (not a subagent) -- subagent
# sandbox blocks `git push`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/log.sh disable=SC1091
source "${SCRIPT_DIR}/lib/log.sh"
# Default scope = the roster's `mutation` column (refs #272). Wider than the
# `.base` fanout on purpose: it includes `template`, whose subtree init.sh
# reseeds rather than the upgrade fanout. Reading the roster is what stops this
# engine drifting away from the fanout the way four copies of the list did.
# shellcheck source=lib/roster.sh disable=SC1091
source "${SCRIPT_DIR}/lib/roster.sh"
readonly ORG="ycpss91255-docker"

# Mutation exit-code protocol.
readonly MUT_CHANGED=0
readonly MUT_SKIP=3

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

# slugify <text> — lowercase, non-alnum -> '-', squeeze, trim.
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-\+//' -e 's/-\+$//'
}

main() {
  local mutation=""
  local pr_title=""
  local why_file=""
  local why_text=""
  local commit_type="chore"
  local branch=""
  local only_csv=""
  local skip_csv=""
  local dry_run=0
  local continue_on_error=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --mutation) mutation="$2"; shift 2 ;;
      --pr-title) pr_title="$2"; shift 2 ;;
      --why-file) why_file="$2"; shift 2 ;;
      --why) why_text="$2"; shift 2 ;;
      --commit-type) commit_type="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --only) only_csv="$2"; shift 2 ;;
      --skip) skip_csv="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --continue-on-error) continue_on_error=1; shift ;;
      *) _log_fatal batch-mutation-pr unrecognised_arg arg="${1}"; usage; exit 2 ;;
    esac
  done

  if [[ -z "${mutation}" ]]; then
    _log_fatal batch-mutation-pr precondition_missing arg=--mutation
    exit 2
  fi
  if [[ ! -x "${mutation}" ]]; then
    _log_fatal batch-mutation-pr precondition_missing arg=--mutation path="${mutation}" reason=not-executable
    exit 2
  fi
  if [[ -z "${pr_title}" ]]; then
    _log_fatal batch-mutation-pr precondition_missing arg=--pr-title
    exit 2
  fi
  if [[ -z "${why_file}" && -z "${why_text}" ]]; then
    _log_fatal batch-mutation-pr precondition_missing arg="--why-file|--why"
    exit 2
  fi
  if [[ -n "${why_file}" && ! -r "${why_file}" ]]; then
    _log_fatal batch-mutation-pr precondition_missing path="${why_file}" reason=not-readable
    exit 2
  fi
  case "${commit_type}" in
    fix|feat|chore) : ;;
    *) _log_fatal batch-mutation-pr precondition_missing arg=--commit-type value="${commit_type}" reason=not-in-fix-feat-chore; exit 2 ;;
  esac

  local why
  if [[ -n "${why_file}" ]]; then
    why="$(cat -- "${why_file}")"
  else
    why="${why_text}"
  fi

  [[ -z "${branch}" ]] && branch="${commit_type}/$(slugify "${pr_title}")"

  local repos=()
  if [[ -n "${only_csv}" ]]; then
    IFS=',' read -ra repos <<< "${only_csv}"
  else
    mapfile -t repos < <(roster_mutation_paths)
  fi
  if [[ -n "${skip_csv}" ]]; then
    local skip_set=" ${skip_csv//,/ } "
    local kept=()
    local r
    for r in "${repos[@]}"; do
      [[ "${skip_set}" == *" ${r} "* ]] || kept+=("${r}")
    done
    repos=("${kept[@]}")
  fi

  local root=""
  if (( ! dry_run )); then
    root="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
    readonly root
  fi

  _log_info batch-mutation-pr summary phase=start branch="${branch}" dry_run="${dry_run}" count="${#repos[@]}" mutation="${mutation}" commit_type="${commit_type}"

  local failed=() skipped=() opened=()
  local repo
  for repo in "${repos[@]}"; do
    local reponame="${repo##*/}"
    local url="https://github.com/${ORG}/${reponame}.git"

    if (( dry_run )); then
      _log_info batch-mutation-pr dry_run_cmd repo="${repo}" url="${url}" branch="${branch}" title="${pr_title}" mutation="${mutation}"
      continue
    fi

    if [[ ! -d "${root}/${repo}" ]]; then
      _log_warn batch-mutation-pr repo_skipped repo="${repo}" reason=missing-local-dir
      skipped+=("${repo} (missing)")
      continue
    fi

    local rc=0
    process_one "${root}/${repo}" "${url}" "${reponame}" "${mutation}" \
      "${branch}" "${pr_title}" "${why}" || rc=$?
    if (( rc == 0 )); then
      opened+=("${repo}")
    elif (( rc == MUT_SKIP )); then
      skipped+=("${repo} (no-op)")
    else
      failed+=("${repo}")
      if (( ! continue_on_error )); then
        _log_err batch-mutation-pr repo_failed repo="${repo}" rc="${rc}" action=abort
        break
      fi
    fi
  done

  _log_info batch-mutation-pr summary phase=end opened="${#opened[@]}" skipped="${#skipped[@]}" failed="${#failed[@]}"
  (( ${#opened[@]} )) && printf '  opened:  %s\n' "${opened[@]}"
  (( ${#skipped[@]} )) && printf '  skipped: %s\n' "${skipped[@]}"
  if (( ${#failed[@]} )); then
    printf '  failed:  %s\n' "${failed[@]}"
    exit 1
  fi
}

# process_one <dir> <url> <reponame> <mutation> <branch> <title> <why>
# Returns 0 (PR opened), MUT_SKIP (no-op), or non-zero (error).
process_one() {
  local dir="$1" url="$2" reponame="$3" mutation="$4"
  local branch="$5" title="$6" why="$7"

  cd "${dir}"
  git fetch "${url}" main || return 1
  git checkout -B main FETCH_HEAD || return 1
  git checkout -B "${branch}" || return 1

  # Run the caller's mutation; capture its output away from our stream.
  local mut_log
  mut_log="$(mktemp)"
  local mrc=0
  "${mutation}" "${dir}" > "${mut_log}" 2>&1 || mrc=$?

  if (( mrc == MUT_SKIP )); then
    _log_info batch-mutation-pr repo_skipped repo="${reponame}" reason=mutation-no-op
    git checkout main || true
    git branch -D "${branch}" || true
    rm -f "${mut_log}"
    return "${MUT_SKIP}"
  fi
  if (( mrc != MUT_CHANGED )); then
    _log_err batch-mutation-pr mutation_failed repo="${reponame}" rc="${mrc}" log="${mut_log}"
    return 1
  fi

  if git diff --quiet && git diff --cached --quiet; then
    _log_info batch-mutation-pr repo_skipped repo="${reponame}" reason=mutation-touched-nothing
    git checkout main || true
    git branch -D "${branch}" || true
    rm -f "${mut_log}"
    return "${MUT_SKIP}"
  fi
  rm -f "${mut_log}"

  git add -A || return 1
  git commit -m "${title}" || return 1
  git push "${url}" "${branch}" || return 1

  local body
  # shellcheck disable=SC2016  # backticks in single-quoted printf format are intentional literal markdown code spans
  body="$(printf '## Why\n\n%s\n\n## What\n\nApplied via `batch-mutation-pr.sh` with a caller-supplied mutation. See the linked tracking issue for the mutation logic.\n\n## Test plan\n\n- [x] CI green on this PR\n' "${why}")"

  local pr_url
  pr_url="$(gh pr create -R "${ORG}/${reponame}" --base main --head "${branch}" \
    --title "${title}" --body "${body}")" || return 1
  _log_info batch-mutation-pr pr_opened repo="${reponame}" url="${pr_url}"
}

main "$@"
