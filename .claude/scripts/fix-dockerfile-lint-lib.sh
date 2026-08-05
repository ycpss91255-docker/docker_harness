#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

# fix-dockerfile-lint-lib.sh
#
# Patch downstream Dockerfiles that pre-date the #284 sub-libs split.
# 12 downstream Dockerfiles miss `COPY .base/script/docker/lib /lint/lib`
# after #284 split _lib.sh into focused sub-libs under
# script/docker/lib/. The split was bundled in v0.28.0 but the v0.28.0 /
# v0.27.0 cycles only fanned out subtree content; downstream Dockerfiles
# (which are repo-local, NOT subtree) were never patched. v0.28.1+
# fanout's `bats /smoke_test/` triggers the latent gap:
#
#   /lint/_lib.sh: line 38: /lint/lib/log.sh: No such file or directory
#
# This script patches each <branch> in-place by (a) adding the COPY line
# just before the `RUN shellcheck ...` line, and (b) extending that
# RUN shellcheck invocation to also cover the new /lint/lib/*.sh files.
# Idempotent: re-running on a patched branch is a no-op.
#
# ros1_bridge was hand-patched at the v0.28.0 cycle when it was the
# first repo to adopt the lib/ structure. The idempotency check skips
# it automatically -- the REPOS array can safely include it.
#
# After all branches are patched + pushed, the existing chore PRs
# auto-rerun their CI. Use the wait-pr-ci-batch.sh + batch-pr-merge.sh
# step block printed by /batch-base-upgrade as next.
#
# Long-term: upgrade.sh should auto-detect-and-patch this drift so each
# fanout heals itself. Tracked separately.
#
# Usage:
#   fix-dockerfile-lint-lib.sh --branch <branch> [options]
#
# Options:
#   --branch <name>      Required. Chore branch to patch in each repo
#                        (e.g. chore/base-v0.28.2).
#   --org <owner>        GitHub owner for clones (default: ycpss91255-docker).
#   --repos <r1,r2,...>  Comma-separated short repo names (default: every
#                        .base consumer in lib/roster.tsv, active or parked --
#                        the patch is idempotent and pre-dates the pauses).
#   --dry-run            Print plan and exit without cloning / pushing.
#   -h, --help           Show this help.
#
# Run from workspace root.

set -euo pipefail

_FDLL_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=lib/log.sh disable=SC1091
source "${_FDLL_SCRIPT_DIR}/lib/log.sh"

readonly DEFAULT_ORG='ycpss91255-docker'
# Default scope comes from lib/roster.tsv (refs #272). The hardcoded list this
# replaced still named `realsense_humble` / `realsense_noetic`, renamed away
# long before -- which is the whole reason a hand-kept copy is the bug: a
# generic, re-runnable fanout helper silently defaulted to two repos that no
# longer exist. `all` here, not `active`: a Dockerfile patch is idempotent and
# is worth applying to a parked consumer the moment its fanout resumes.
# shellcheck source=lib/roster.sh disable=SC1091
source "${_FDLL_SCRIPT_DIR}/lib/roster.sh"

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
      *) _log_fatal fix-lint-lib unrecognised_arg arg="${1}"; usage; exit 2 ;;
    esac
  done

  if [[ -z "${branch}" ]]; then
    _log_fatal fix-lint-lib precondition_missing arg=--branch
    usage
    exit 2
  fi

  local -a repos=()
  if [[ -n "${repos_csv}" ]]; then
    IFS=',' read -r -a repos <<< "${repos_csv}"
  else
    mapfile -t repos < <(roster_fanout_repos all)
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
    _log_info fix-lint-lib processing_repo repo="${repo}"

    if (( dry_run )); then
      _log_info fix-lint-lib dry_run_cmd repo="${repo}" org="${org}" branch="${branch}" action="clone+patch+push"
      continue
    fi

    workdir="${TMPDIR_FIX}/${repo}"

    if ! gh repo clone "${org}/${repo}" "${workdir}" -- --quiet --depth=1 --branch="${branch}" 2>/dev/null; then
      _log_err fix-lint-lib repo_failed repo="${repo}" reason=clone-failed branch="${branch}"
      failed=$((failed + 1))
      failed_repos+=("${repo}")
      continue
    fi

    # Per-repo git identity (shallow clones inherit no global identity in
    # sandboxed environments). Inherit from outer workspace's git config.
    git -C "${workdir}" config user.name  "$(git config --get user.name)"
    git -C "${workdir}" config user.email "$(git config --get user.email)"

    if [[ ! -f "${workdir}/Dockerfile" ]]; then
      _log_warn fix-lint-lib patch_skipped repo="${repo}" reason=no-dockerfile
      skipped=$((skipped + 1))
      skipped_repos+=("${repo}")
      continue
    fi

    if grep -qE '^COPY .base/script/docker/lib(/|$)' "${workdir}/Dockerfile"; then
      _log_info fix-lint-lib patch_skipped repo="${repo}" reason=already-patched
      skipped=$((skipped + 1))
      skipped_repos+=("${repo}")
      continue
    fi

    if ! grep -qE '^RUN shellcheck -S warning /lint/\*\.sh$' "${workdir}/Dockerfile"; then
      _log_err fix-lint-lib patch_failed repo="${repo}" reason=anchor-not-found anchor="RUN shellcheck -S warning /lint/*.sh"
      failed=$((failed + 1))
      failed_repos+=("${repo}")
      continue
    fi

    sed -i '/^RUN shellcheck -S warning \/lint\/\*\.sh$/i COPY .base/script/docker/lib /lint/lib' "${workdir}/Dockerfile"
    sed -i 's|^RUN shellcheck -S warning /lint/\*\.sh$|RUN shellcheck -S warning /lint/*.sh /lint/lib/*.sh|' "${workdir}/Dockerfile"

    if ! git -C "${workdir}" diff --quiet -- Dockerfile; then
      git -C "${workdir}" add Dockerfile
      if ! git -C "${workdir}" commit -m "fix(dockerfile): COPY .base/script/docker/lib /lint/lib for shellcheck + smoke (post-#306 follow-up)"; then
        _log_err fix-lint-lib patch_failed repo="${repo}" reason=commit-failed
        failed=$((failed + 1))
        failed_repos+=("${repo}")
        continue
      fi
      if ! git -C "${workdir}" push origin "${branch}" 2>&1 | tail -3; then
        _log_err fix-lint-lib patch_failed repo="${repo}" reason=push-failed
        failed=$((failed + 1))
        failed_repos+=("${repo}")
        continue
      fi
      opened=$((opened + 1))
      opened_repos+=("${repo}")
      _log_info fix-lint-lib patch_applied repo="${repo}"
    else
      _log_warn fix-lint-lib patch_skipped repo="${repo}" reason=sed-no-diff
      skipped=$((skipped + 1))
      skipped_repos+=("${repo}")
    fi
  done

  _log_info fix-lint-lib summary patched="${opened}" skipped="${skipped}" failed="${failed}"
  local r
  for r in "${opened_repos[@]}"; do printf '  patched: %s\n' "${r}"; done
  for r in "${skipped_repos[@]}"; do printf '  skipped: %s\n' "${r}"; done
  for r in "${failed_repos[@]}"; do printf '  failed:  %s\n' "${r}"; done

  if (( failed > 0 )); then
    exit 1
  fi
}

main "$@"
