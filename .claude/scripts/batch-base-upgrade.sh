#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

#
# Batch-upgrade all downstream repos under ycpss91255-docker to a target
# template tag. Iterates a fixed repo list, fetches main via HTTPS (works
# around stale SSH origin tracking), creates chore/base-<tag> branch,
# runs ./.base/upgrade.sh + ./.base/init.sh, opens a PR per repo.
#
# Usage:
#   batch-base-upgrade.sh <version> --why-file <path> [options]
#   batch-base-upgrade.sh <version> --why "<text>" [options]
#
# Options:
#   --why-file <path>      PR body Why-section content (required, or use --why)
#   --why "<text>"         Inline alternative to --why-file
#   --issue <num>          Tracking issue number for PR body (optional)
#   --dry-run              Print what would be done; skip mutations
#   --only <r1,r2,...>     Limit to listed repos (relative paths, e.g. agent/ai_agent)
#   --skip <r1,r2,...>     Exclude listed repos
#   --continue-on-error    Keep going past failed repos; print summary at end
#   -h, --help             Show this help
#
# Designed to be run from the main session (not a subagent) because subagent
# sandbox blocks git push.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/log.sh disable=SC1091
source "${SCRIPT_DIR}/lib/log.sh"
readonly DEFAULT_PR_BODY_TEMPLATE="${SCRIPT_DIR}/batch-base-pr-body.template.md"
readonly ORG="ycpss91255-docker"

readonly DEFAULT_REPOS=(
  # NOTE: 10 downstream repos parked pending follow-up.
  #   - 4 agent repos: archive pending (no concrete container plan)
  #   - 3 app repos (ros1_bridge, sick_humble, sick_noetic): archive pending
  #     (functionally covered by env/ros_distro + env/ros2_distro)
  #   - 3 sensor repos still parked (urg_node_humble/noetic,
  #     realsense_ros1): pending template->base subtree migration; the
  #     realsense rename is done (realsense_noetic -> realsense_ros1),
  #     urg_node still pending rename to urg_node_ros{,2}.
  #     realsense_ros2 migrated + renamed (active below).
  # Uncomment a repo's line once its prerequisite work merges.
  # agent/ai_agent
  # agent/claude_code
  # agent/codex_cli
  # agent/gemini_cli
  # app/realsense_ros1
  # app/ros1_bridge
  # app/sick_humble
  # app/sick_noetic
  # app/urg_node_humble
  # app/urg_node_noetic
  app/realsense_ros2
  env/ros2_distro
  env/ros_distro
)

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

main() {
  local version=""
  local why_file=""
  local why_text=""
  local issue=""
  local dry_run=0
  local continue_on_error=0
  local only_csv=""
  local skip_csv=""

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --why-file) why_file="$2"; shift 2 ;;
      --why) why_text="$2"; shift 2 ;;
      --issue) issue="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --continue-on-error) continue_on_error=1; shift ;;
      --only) only_csv="$2"; shift 2 ;;
      --skip) skip_csv="$2"; shift 2 ;;
      v[0-9]*) version="$1"; shift ;;
      *) _log_fatal batch-base-upgrade unrecognised_arg arg="${1}"; usage; exit 2 ;;
    esac
  done

  if [[ -z "${version}" ]]; then
    _log_fatal batch-base-upgrade precondition_missing arg="<version>" hint="e.g. v0.12.1"
    usage
    exit 2
  fi
  if [[ -z "${why_file}" && -z "${why_text}" ]]; then
    _log_fatal batch-base-upgrade precondition_missing arg="--why-file|--why"
    exit 2
  fi
  if [[ -n "${why_file}" && ! -r "${why_file}" ]]; then
    _log_fatal batch-base-upgrade precondition_missing path="${why_file}" reason=not-readable
    exit 2
  fi
  if [[ ! -r "${DEFAULT_PR_BODY_TEMPLATE}" ]]; then
    _log_fatal batch-base-upgrade precondition_missing path="${DEFAULT_PR_BODY_TEMPLATE}" reason=not-found
    exit 2
  fi

  local why
  if [[ -n "${why_file}" ]]; then
    why="$(cat -- "${why_file}")"
  else
    why="${why_text}"
  fi

  local repos=()
  if [[ -n "${only_csv}" ]]; then
    IFS=',' read -ra repos <<< "${only_csv}"
  else
    repos=("${DEFAULT_REPOS[@]}")
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

  local root
  root="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
  readonly root

  local branch="chore/base-${version}"
  local issue_line=""
  if [[ -n "${issue}" ]]; then
    issue_line="Closes part of ${ORG}/template#${issue}."
  fi

  _log_info batch-base-upgrade summary phase=start version="${version}" branch="${branch}" dry_run="${dry_run}" count="${#repos[@]}"

  local failed=()
  local skipped=()
  local opened=()

  local pairs_file
  pairs_file="$(mktemp)"
  # shellcheck disable=SC2064  # pairs_file is set, expansion at trap-set is fine
  trap "rm -f '${pairs_file}'" EXIT

  local repo
  for repo in "${repos[@]}"; do
    local reponame="${repo##*/}"
    local url="https://github.com/${ORG}/${reponame}.git"
    _log_info batch-base-upgrade processing_repo repo="${repo}"

    if [[ ! -d "${root}/${repo}" ]]; then
      _log_warn batch-base-upgrade repo_skipped repo="${repo}" reason=missing-local-dir
      skipped+=("${repo} (missing)")
      continue
    fi

    if (( dry_run )); then
      _log_info batch-base-upgrade dry_run_cmd repo="${repo}" url="${url}" branch="${branch}" version="${version}"
      continue
    fi

    if upgrade_one "${root}/${repo}" "${url}" "${branch}" "${version}" "${reponame}" "${why}" "${issue_line}" "${pairs_file}"; then
      opened+=("${repo}")
    else
      local rc=$?
      if (( rc == 100 )); then
        skipped+=("${repo} (already at ${version})")
      else
        failed+=("${repo}")
        if (( ! continue_on_error )); then
          _log_err batch-base-upgrade repo_failed repo="${repo}" rc="${rc}" action=abort hint="use --continue-on-error to keep going"
          break
        fi
      fi
    fi
  done

  local opened_pairs=()
  if [[ -s "${pairs_file}" ]]; then
    local line
    while IFS= read -r line; do
      [[ -n "${line}" ]] && opened_pairs+=("${line}")
    done < "${pairs_file}"
  fi

  _log_info batch-base-upgrade summary phase=end opened="${#opened[@]}" skipped="${#skipped[@]}" failed="${#failed[@]}"
  if (( ${#opened[@]} )); then
    printf '  opened:  %s\n' "${opened[@]}"
  fi
  if (( ${#skipped[@]} )); then
    printf '  skipped: %s\n' "${skipped[@]}"
  fi

  print_next_step_hint "${opened_pairs[@]}"

  if (( ${#failed[@]} )); then
    printf '  failed:  %s\n' "${failed[@]}"
    exit 1
  fi
}

upgrade_one() {
  local dir="$1"
  local url="$2"
  local branch="$3"
  local version="$4"
  local reponame="$5"
  local why="$6"
  local issue_line="$7"
  local pairs_file="${8:-}"

  cd "${dir}"

  git fetch "${url}" main || return 1
  git checkout -B main FETCH_HEAD || return 1
  git checkout -B "${branch}" || return 1

  # One-shot pre-upgrade migration for template #201 (v0.16.0).
  # Renames setup.conf.local → setup.conf and drops the obsolete
  # `setup.conf` line from .gitignore. Idempotent: skips on repos that
  # have already migrated. Delete this block (and the script it calls)
  # after the v0.16.x cycle.
  if [[ -f "${dir}/setup.conf.local" ]] \
      && [[ -x "${SCRIPT_DIR}/migrate-local-to-setupconf.sh" ]]; then
    "${SCRIPT_DIR}/migrate-local-to-setupconf.sh" "${dir}" || return 1
    git commit -m "chore: migrate setup.conf.local to setup.conf for ${version} (#201)" \
      || return 1
  fi

  ./.base/upgrade.sh "${version}" || return 1
  ./.base/init.sh || return 1

  # Skip only if the branch is fully equivalent to main: no commits ahead
  # AND no uncommitted edits AND no untracked files. `git diff --quiet HEAD`
  # alone misses the upgrade case — upgrade.sh commits its work, so HEAD vs
  # working-tree is always clean even when the branch carries a real upgrade.
  if git diff --quiet main HEAD \
     && git diff --quiet \
     && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
    _log_info batch-base-upgrade repo_skipped repo="${reponame}" reason=already-at-version version="${version}"
    git checkout main || return 1
    git branch -D "${branch}" || return 1
    return 100
  fi

  if ! git diff --quiet || git ls-files --others --exclude-standard | grep -q .; then
    git add -A
    git commit -m "chore: re-run init.sh after template ${version} pull" || true
  fi

  git push "${url}" "${branch}" || return 1

  local body
  body="$(render_pr_body "${version}" "${why}" "${issue_line}")"

  local pr_url
  pr_url="$(gh pr create -R "${ORG}/${reponame}" --base main --head "${branch}" \
    --title "chore: upgrade template subtree to ${version}" \
    --body "${body}")" || return 1

  _log_info batch-base-upgrade pr_opened repo="${reponame}" url="${pr_url}"

  if [[ -n "${pairs_file}" ]]; then
    local pr_num="${pr_url##*/}"
    if [[ "${pr_num}" =~ ^[0-9]+$ ]]; then
      printf '%s:%s\n' "${reponame}" "${pr_num}" >> "${pairs_file}"
    fi
  fi
}

render_pr_body() {
  local version="$1"
  local why="$2"
  local issue_line="$3"

  # shellcheck disable=SC2016  # envsubst placeholders must stay literal
  VERSION="${version}" \
  WHY="${why}" \
  ISSUE_LINE="${issue_line}" \
    envsubst '${VERSION} ${WHY} ${ISSUE_LINE}' < "${DEFAULT_PR_BODY_TEMPLATE}"
}

# print_next_step_hint <pair...>
#
# Pair format: <reponame>:<pr_num> (e.g. ai_agent:194). Emits a copy-pasteable
# wait-pr-ci-batch.sh + batch-pr-merge.sh block on stdout. Silent when called
# with zero pairs (dry-run, all-skipped, or all-failed runs).
print_next_step_hint() {
  local pairs=("$@")
  if (( ${#pairs[@]} == 0 )); then
    return 0
  fi
  echo
  echo "next: wait CI then merge:"
  printf '  .claude/scripts/wait-pr-ci-batch.sh %s \\\n' "${pairs[*]}"
  printf "    --check-filter '.name==\"call-docker-build / docker-build\"'\n"
  printf '  .claude/scripts/batch-pr-merge.sh --reset-local %s\n' "${pairs[*]}"
  printf '\n'
  printf '  # --reset-local closes the detached-HEAD aftermath on each\n'
  printf '  # local main checkout (this script operates on main checkouts,\n'
  printf '  # not worktrees, so after GitHub squash-merges the chore branch,\n'
  printf '  # local main lands one squash-commit behind origin/main on a\n'
  printf '  # detached HEAD). Drop --reset-local if you prefer to keep the\n'
  printf '  # divergent state.\n'
}

# Allow sourcing for unit tests without auto-running main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
