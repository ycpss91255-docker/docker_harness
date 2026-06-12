#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

#
# batch-gitignore-fix.sh — open one chore PR per downstream repo to
# loosen `.gitignore` so the per-repo `<repo>/.claude` symlinks (used
# by per-repo Claude sessions) stop showing as `?? .claude` in
# `git status`.
#
# Each repo currently has `.claude/` in its `.gitignore` (trailing
# slash = directory only). Replace with `.claude` (no slash, also
# matches symlinks).
#
# Usage:
#   batch-gitignore-fix.sh --why-file <path> [options]
#   batch-gitignore-fix.sh --why "<text>"   [options]
#
# Options:
#   --why-file <path>     PR body Why-section content (required, or use --why)
#   --why "<text>"        Inline alternative
#   --dry-run             Print what would be done; skip mutations
#   --only <r1,r2,...>    Limit to listed repos (relative paths, e.g. agent/ai_agent)
#   --skip <r1,r2,...>    Exclude listed repos
#   --continue-on-error   Keep going past failures; print summary at end
#   -h, --help            Show this help
#
# Designed to be run from the main session (not a subagent) because
# subagent sandbox blocks git push.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/log.sh disable=SC1091
source "${SCRIPT_DIR}/lib/log.sh"
readonly ORG="ycpss91255-docker"
readonly BRANCH="chore/gitignore-claude-symlink"
readonly TITLE="chore: gitignore .claude (also covers symlinks)"

readonly DEFAULT_REPOS=(
  agent/ai_agent
  agent/claude_code
  agent/codex_cli
  agent/gemini_cli
  app/realsense_ros2
  app/realsense_noetic
  app/ros1_bridge
  app/sick_humble
  app/sick_noetic
  app/urg_node_humble
  app/urg_node_noetic
  env/osrf_ros2_humble
  env/osrf_ros_kinetic
  env/osrf_ros_noetic
  env/ros2_humble
  env/ros_kinetic
  env/ros_noetic
  template
)

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

main() {
  local why_file=""
  local why_text=""
  local dry_run=0
  local continue_on_error=0
  local only_csv=""
  local skip_csv=""

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --why-file) why_file="$2"; shift 2 ;;
      --why) why_text="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --continue-on-error) continue_on_error=1; shift ;;
      --only) only_csv="$2"; shift 2 ;;
      --skip) skip_csv="$2"; shift 2 ;;
      *) _log_fatal batch-gitignore-fix unrecognised_arg arg="${1}"; usage; exit 2 ;;
    esac
  done

  if [[ -z "${why_file}" && -z "${why_text}" ]]; then
    _log_fatal batch-gitignore-fix precondition_missing arg="--why-file|--why"
    exit 2
  fi
  if [[ -n "${why_file}" && ! -r "${why_file}" ]]; then
    _log_fatal batch-gitignore-fix precondition_missing path="${why_file}" reason=not-readable
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

  # Lazy: only resolve the workspace root if we actually mutate. Lets
  # `--help` / `--dry-run` work outside a git checkout (e.g. inside the
  # bats test container where /work is just a mount, not a git repo).
  local root=""
  if (( ! dry_run )); then
    root="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
    readonly root
  fi

  _log_info batch-gitignore-fix summary phase=start branch="${BRANCH}" dry_run="${dry_run}" count="${#repos[@]}"

  local failed=()
  local skipped=()
  local opened=()

  local repo
  for repo in "${repos[@]}"; do
    local reponame="${repo##*/}"
    local url="https://github.com/${ORG}/${reponame}.git"
    _log_info batch-gitignore-fix processing_repo repo="${repo}"

    if (( dry_run )); then
      _log_info batch-gitignore-fix dry_run_cmd repo="${repo}" url="${url}" branch="${BRANCH}" action="sed .claude/ to .claude"
      continue
    fi

    if [[ ! -d "${root}/${repo}" ]]; then
      _log_warn batch-gitignore-fix repo_skipped repo="${repo}" reason=missing-local-dir
      skipped+=("${repo} (missing)")
      continue
    fi
    if [[ ! -f "${root}/${repo}/.gitignore" ]]; then
      _log_info batch-gitignore-fix repo_skipped repo="${repo}" reason=no-gitignore
      skipped+=("${repo} (no .gitignore)")
      continue
    fi

    if fix_one "${root}/${repo}" "${url}" "${reponame}" "${why}"; then
      opened+=("${repo}")
    else
      local rc=$?
      if (( rc == 100 )); then
        skipped+=("${repo} (already fixed)")
      else
        failed+=("${repo}")
        if (( ! continue_on_error )); then
          _log_err batch-gitignore-fix repo_failed repo="${repo}" rc="${rc}" action=abort
          break
        fi
      fi
    fi
  done

  _log_info batch-gitignore-fix summary phase=end opened="${#opened[@]}" skipped="${#skipped[@]}" failed="${#failed[@]}"
  if (( ${#opened[@]} )); then
    printf '  opened:  %s\n' "${opened[@]}"
  fi
  if (( ${#skipped[@]} )); then
    printf '  skipped: %s\n' "${skipped[@]}"
  fi
  if (( ${#failed[@]} )); then
    printf '  failed:  %s\n' "${failed[@]}"
    exit 1
  fi
}

fix_one() {
  local dir="$1"
  local url="$2"
  local reponame="$3"
  local why="$4"

  cd "${dir}"

  git fetch "${url}" main || return 1
  git checkout -B main FETCH_HEAD || return 1

  # Idempotency: if .gitignore no longer has the old `.claude/` line,
  # treat as already fixed and skip without opening a PR.
  if ! grep -qE '^\.claude/$' .gitignore; then
    _log_info batch-gitignore-fix repo_skipped repo="${reponame}" reason=already-fixed
    return 100
  fi

  git checkout -B "${BRANCH}" || return 1

  # Replace the line `.claude/` (alone) with `.claude` (no trailing slash).
  sed -i 's|^\.claude/$|.claude|' .gitignore

  if git diff --quiet; then
    _log_info batch-gitignore-fix repo_skipped repo="${reponame}" reason=sed-no-change
    git checkout main || return 1
    git branch -D "${BRANCH}" || return 1
    return 100
  fi

  git add .gitignore
  git commit -m "${TITLE}" \
    -m "Replace \`.claude/\` (directory-only) with \`.claude\` so the pattern also covers symlinks (used by per-repo Claude sessions in the docker monorepo). No code or build impact." \
    || return 1

  git push "${url}" "${BRANCH}" || return 1

  local body
  # shellcheck disable=SC2016  # backticks inside single quotes are intentionally literal markdown code spans
  body="$(printf '## Why\n\n%s\n\n## What\n\nReplace `.claude/` with `.claude` in `.gitignore` so the pattern matches both directories AND symlinks. The trailing slash form (`.claude/`) only matches a real directory; the docker monorepo creates `<repo>/.claude` as a symlink to the workspace `.claude/`, which leaks into `git status` as `?? .claude` under the old pattern.\n\nNo code, Dockerfile, or test impact.\n\n## Test plan\n\n- [x] CI green on this PR\n- After merge: confirm `git status` no longer flags `.claude` symlink in this repo\n' "${why}")"

  local pr_url
  pr_url="$(gh pr create -R "${ORG}/${reponame}" --base main --head "${BRANCH}" \
    --title "${TITLE}" \
    --body "${body}")" || return 1

  _log_info batch-gitignore-fix pr_opened repo="${reponame}" url="${pr_url}"
}

main "$@"
