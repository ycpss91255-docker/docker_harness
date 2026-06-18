#!/usr/bin/env bash
# log-allow:script -- emits data-product output (CI passthrough + next-step / stamp notice) alongside _log_*; per-callsite split deferred until tooling can distinguish.

#
# ci-and-stamp.sh -- run a repo's full CI mirror and, on green, write the
# local-ci-pass marker that enforce_local_full_ci_before_pr.sh checks
# (refs #208 / #176).
#
# The PR gate (`enforce_local_full_ci_before_pr.sh`) fires for ANY
# repo's worktree but the marker was originally written only by
# docker_harness's own `.claude/test/Makefile`, so base / downstream
# PRs were always denied. This helper centralises marker-writing on the
# docker_harness side: it detects the target repo's CI command, runs the
# FULL CI mirror (so the marker attests "GH CI will pass", not merely
# "tests pass"), and stamps only on green. The marker convention stays
# entirely here -- base's `justfile.ci` does not carry it.
#
# Usage:
#   ci-and-stamp.sh [<repo-path>]      # default: cwd
#
# Detection (mutually exclusive across repos):
#   <root>/.claude/test/Makefile  -> docker_harness -> make -C .claude/test check
#   <root>/justfile.ci            -> base           -> just -f justfile.ci test && lint
#   <root>/justfile (-> .base)    -> downstream     -> ./build.sh test
#   none of the above             -> no CI mechanism -> do NOT stamp,
#                                    exit 0 with a notice (the gate
#                                    fail-opens for such repos)
#
# Exit: the CI command's exit code (0 = green + stamped). On a no-CI
# repo: 0 (nothing to run, nothing to stamp).
#
# Run from the main session (not a subagent) -- subagent sandbox blocks
# docker.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/log.sh disable=SC1091
source "${SCRIPT_DIR}/lib/log.sh"

readonly MARKER_SUBDIR=".claude/state/local-ci-pass"

stamp() {
  local root="$1" head
  head="$(git -C "${root}" rev-parse HEAD 2>/dev/null)" || return 0
  mkdir -p "${root}/${MARKER_SUBDIR}" 2>/dev/null || return 0
  ( : > "${root}/${MARKER_SUBDIR}/${head}.ok" ) 2>/dev/null || true
  _log_info ci-and-stamp marker_written repo="${root}" head="${head:0:8}"
}

main() {
  local target="${1:-${PWD}}"
  local root
  root="$(git -C "${target}" rev-parse --show-toplevel 2>/dev/null)" || {
    _log_fatal ci-and-stamp precondition_missing path="${target}" reason=not-a-git-repo
    exit 2
  }

  local rc
  if [[ -f "${root}/.claude/test/Makefile" ]]; then
    _log_info ci-and-stamp ci_start kind=docker_harness cmd="make -C .claude/test check"
    make -C "${root}/.claude/test" check
    rc=$?
  elif [[ -f "${root}/justfile.ci" ]]; then
    _log_info ci-and-stamp ci_start kind=base cmd="just -f justfile.ci test+lint"
    ( cd "${root}" && just -f justfile.ci test && just -f justfile.ci lint )
    rc=$?
  elif [[ -f "${root}/justfile" ]]; then
    _log_info ci-and-stamp ci_start kind=downstream cmd="./build.sh test"
    ( cd "${root}" && ./build.sh test )
    rc=$?
  else
    _log_warn ci-and-stamp no_ci_mechanism repo="${root}" reason=no-makefile-justfile.ci-justfile
    return 0
  fi

  if (( rc == 0 )); then
    stamp "${root}"
  else
    _log_err ci-and-stamp ci_failed repo="${root}" rc="${rc}" action=no-stamp
  fi
  return "${rc}"
}

main "$@"
