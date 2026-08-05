#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

# fix-dockerfile-copy-script.sh
#
# Patch downstream Dockerfiles for the v0.31.0 wrapper consolidation
# (ycpss91255-docker/base#330, shipped via #359). v0.31.0 moves the
# seven user-facing wrappers (build.sh / run.sh / exec.sh / stop.sh /
# prune.sh / setup.sh / setup_tui.sh) from the repo root into a
# script/ subfolder. Downstream Dockerfiles that lint the wrappers
# via `COPY *.sh /lint/` were anchored at the repo root, so after the
# subtree upgrade the COPY pulls in zero files and `bats /smoke_test/`
# fails on `build.sh -h exits 0` / `run.sh contains XDG_SESSION_TYPE
# check` (grep /lint/run.sh: No such file or directory).
#
# This script patches each <branch> in-place: `COPY *.sh /lint/` ->
# `COPY script/*.sh /lint/`. Idempotent: a branch already on the new
# path is a no-op. Surfaced during v0.31.0-rc1 RC validation on
# env/ros_distro (commit 32624a3 on the closed RC PR).
#
# Long-term: ycpss91255-docker/base's upgrade.sh could detect and
# auto-patch this drift so each fanout heals itself. Modelled directly
# on the [[fix-dockerfile-lint-lib]] precedent (#284 sub-libs split).
#
# After all branches are patched + pushed, the existing chore PRs
# auto-rerun their CI. Use the wait-pr-ci-batch.sh + batch-pr-merge.sh
# step block printed by /batch-base-upgrade as next.
#
# Usage:
#   fix-dockerfile-copy-script.sh --branch <branch> [options]
#
# Options:
#   --branch <name>      Required. Chore branch to patch in each repo
#                        (e.g. chore/base-v0.31.0).
#   --org <owner>        GitHub owner for clones (default: ycpss91255-docker).
#   --repos <r1,r2,...>  Comma-separated short repo names (default: the
#                        active downstream set from lib/roster.tsv, the same
#                        list /batch-base-upgrade fans out over).
#   --dry-run            Print plan and exit without cloning / pushing.
#   -h, --help           Show this help.
#
# Run from workspace root.

set -euo pipefail

_FDCS_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=lib/log.sh disable=SC1091
source "${_FDCS_SCRIPT_DIR}/lib/log.sh"

readonly DEFAULT_ORG='ycpss91255-docker'
# Default scope comes from lib/roster.tsv (refs #272). `active`, matching this
# helper's stated scope ("the active downstream repos a fanout must patch") --
# the hardcoded pair it replaced was written when that meant two repos and was
# never updated when realsense_ros2 joined, which is exactly the divergence the
# roster exists to make impossible. Its sibling fix-dockerfile-lint-lib.sh asks
# for `all` instead, because its patch predates the parked repos' pause.
# shellcheck source=lib/roster.sh disable=SC1091
source "${_FDCS_SCRIPT_DIR}/lib/roster.sh"

usage() {
  sed -n '/^# Usage:/,/^# Run/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

main() {
  local branch=""
  local org="${DEFAULT_ORG}"
  local dry_run=0
  local repos_csv=""

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --branch) branch="$2"; shift 2 ;;
      --org) org="$2"; shift 2 ;;
      --repos) repos_csv="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) _log_fatal fix-copy-script unrecognised_arg arg="${1}"; usage; exit 2 ;;
    esac
  done

  if [[ -z "${branch}" ]]; then
    _log_fatal fix-copy-script precondition_missing arg=--branch
    usage
    exit 2
  fi

  local -a repos=()
  if [[ -n "${repos_csv}" ]]; then
    IFS=',' read -r -a repos <<< "${repos_csv}"
  else
    mapfile -t repos < <(roster_fanout_repos active)
  fi

  TMPDIR_FIX="$(mktemp -d)"
  trap 'rm -rf "${TMPDIR_FIX}"' EXIT

  local opened=0
  local skipped=0
  local failed=0
  local -a opened_repos=()
  local -a skipped_repos=()
  local -a failed_repos=()

  local repo workdir
  for repo in "${repos[@]}"; do
    _log_info fix-copy-script processing_repo repo="${repo}"

    if (( dry_run )); then
      _log_info fix-copy-script dry_run_cmd repo="${repo}" org="${org}" branch="${branch}" action="clone+patch+push"
      continue
    fi

    workdir="${TMPDIR_FIX}/${repo}"

    if ! gh repo clone "${org}/${repo}" "${workdir}" -- --quiet --depth=1 --branch="${branch}" 2>/dev/null; then
      _log_err fix-copy-script repo_failed repo="${repo}" reason=clone-failed branch="${branch}"
      failed=$((failed + 1))
      failed_repos+=("${repo}")
      continue
    fi

    git -C "${workdir}" config user.name  "$(git config --get user.name)"
    git -C "${workdir}" config user.email "$(git config --get user.email)"

    if [[ ! -f "${workdir}/Dockerfile" ]]; then
      _log_warn fix-copy-script patch_skipped repo="${repo}" reason=no-dockerfile
      skipped=$((skipped + 1))
      skipped_repos+=("${repo}")
      continue
    fi

    if grep -qE '^COPY script/\*\.sh /lint/$' "${workdir}/Dockerfile"; then
      _log_info fix-copy-script patch_skipped repo="${repo}" reason=already-patched
      skipped=$((skipped + 1))
      skipped_repos+=("${repo}")
      continue
    fi

    if ! grep -qE '^COPY \*\.sh /lint/$' "${workdir}/Dockerfile"; then
      _log_err fix-copy-script patch_failed repo="${repo}" reason=anchor-not-found anchor="COPY *.sh /lint/"
      failed=$((failed + 1))
      failed_repos+=("${repo}")
      continue
    fi

    sed -i 's|^COPY \*\.sh /lint/$|COPY script/*.sh /lint/|' "${workdir}/Dockerfile"

    if ! git -C "${workdir}" diff --quiet -- Dockerfile; then
      git -C "${workdir}" add Dockerfile
      if ! git -C "${workdir}" commit -m "fix(dockerfile): COPY script/*.sh /lint/ for v0.31.0 wrapper layout"; then
        _log_err fix-copy-script patch_failed repo="${repo}" reason=commit-failed
        failed=$((failed + 1))
        failed_repos+=("${repo}")
        continue
      fi
      if ! git -C "${workdir}" push origin "${branch}" 2>&1 | tail -3; then
        _log_err fix-copy-script patch_failed repo="${repo}" reason=push-failed
        failed=$((failed + 1))
        failed_repos+=("${repo}")
        continue
      fi
      opened=$((opened + 1))
      opened_repos+=("${repo}")
      _log_info fix-copy-script patch_applied repo="${repo}"
    else
      _log_warn fix-copy-script patch_skipped repo="${repo}" reason=sed-no-diff
      skipped=$((skipped + 1))
      skipped_repos+=("${repo}")
    fi
  done

  _log_info fix-copy-script summary patched="${opened}" skipped="${skipped}" failed="${failed}"
  local r
  for r in "${opened_repos[@]}"; do printf '  patched: %s\n' "${r}"; done
  for r in "${skipped_repos[@]}"; do printf '  skipped: %s\n' "${r}"; done
  for r in "${failed_repos[@]}"; do printf '  failed:  %s\n' "${r}"; done

  if (( failed > 0 )); then
    exit 1
  fi
}

main "$@"
