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
# Detection (first match wins; order matters -- both base and downstream
# now carry a root justfile, so the .base/ subtree distinguishes them):
#   <root>/.claude/test/ci.sh         -> docker_harness -> .claude/test/ci.sh check
#   <root>/justfile  +  <root>/.base/ -> downstream      -> just build test
#   <root>/justfile  (no .base/)      -> base            -> just test && just test lint
#   none of the above             -> no CI mechanism -> do NOT stamp,
#                                    exit 0 with a notice (the gate
#                                    fail-opens for such repos)
#
# Contract (the marker is a green light another tool consumes, so the
# exit status and the marker must never disagree -- refs #261):
#   exit 0  IFF  the whole mirror was green AND the marker for the exact
#                HEAD sha is on disk when the script returns.
# Enforced by construction, not by ordering: the mirror produces one
# verdict, and the script branches on it exactly once. A red run also
# REMOVES any marker an earlier green run left on the same sha (a stale
# green must not survive a later red), and a green run whose marker
# cannot be written reports red rather than an unrecordable pass.
#
# Exit: the CI command's exit code (0 = green + stamped); 1 if the
# mirror was green but the marker could not be written; 2 if the target
# is not a git repo. On a no-CI repo: 0 (nothing to run, nothing to
# stamp).
#
# Run from the main session (not a subagent) -- subagent sandbox blocks
# docker.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/log.sh disable=SC1091
source "${SCRIPT_DIR}/lib/log.sh"

readonly MARKER_SUBDIR=".claude/state/local-ci-pass"

# head_sha <root> -- print <root>'s HEAD sha; non-zero if unresolvable.
head_sha() {
  local head
  head="$(git -C "$1" rev-parse HEAD 2>/dev/null)" || return 1
  [[ -n "${head}" ]] || return 1
  printf '%s\n' "${head}"
}

# stamp <root> -- write the green marker for <root>'s HEAD. Returns
# non-zero (and logs) when it cannot, so the caller turns an
# unrecordable green into a red instead of a pass with no attestation.
stamp() {
  local root="$1" head
  head="$(head_sha "${root}")" || {
    _log_err ci-and-stamp marker_write_failed repo="${root}" reason=head-unresolvable
    return 1
  }
  local dir="${root}/${MARKER_SUBDIR}"
  if ! mkdir -p "${dir}" 2>/dev/null || ! : > "${dir}/${head}.ok" 2>/dev/null; then
    _log_err ci-and-stamp marker_write_failed repo="${root}" head="${head:0:8}" path="${dir}/${head}.ok"
    return 1
  fi
  _log_info ci-and-stamp marker_written repo="${root}" head="${head:0:8}"
}

# unstamp <root> -- drop any marker for <root>'s HEAD. Only that sha is
# touched: markers for other commits attest their own runs.
unstamp() {
  local root="$1" head
  head="$(head_sha "${root}")" || return 0
  local path="${root}/${MARKER_SUBDIR}/${head}.ok"
  [[ -e "${path}" ]] || return 0
  if rm -f "${path}" 2>/dev/null; then
    _log_warn ci-and-stamp stale_marker_removed repo="${root}" head="${head:0:8}"
  else
    _log_err ci-and-stamp stale_marker_removal_failed repo="${root}" head="${head:0:8}" path="${path}"
  fi
}

# detect_kind <root> -- print the repo's CI flavour (first match wins;
# order matters -- both base and downstream carry a root justfile, so
# the vendored .base/ subtree is what distinguishes a consumer).
detect_kind() {
  local root="$1"
  if   [[ -x "${root}/.claude/test/ci.sh" ]];          then printf 'docker_harness\n'
  elif [[ -f "${root}/justfile" && -d "${root}/.base" ]]; then printf 'downstream\n'
  elif [[ -f "${root}/justfile" ]];                    then printf 'base\n'
  else printf 'none\n'
  fi
}

# run_ci <root> <kind> -- run the full CI mirror; returns its exit code.
run_ci() {
  local root="$1" kind="$2"
  case "${kind}" in
    docker_harness)
      _log_info ci-and-stamp ci_start kind=docker_harness cmd=".claude/test/ci.sh check"
      "${root}/.claude/test/ci.sh" check
      ;;
    downstream)
      _log_info ci-and-stamp ci_start kind=downstream cmd="just build test"
      ( cd "${root}" && just build test )
      ;;
    base)
      _log_info ci-and-stamp ci_start kind=base cmd="just test && just test lint"
      ( cd "${root}" && just test && just test lint )
      ;;
  esac
}

main() {
  local target="${1:-${PWD}}"
  local root
  root="$(git -C "${target}" rev-parse --show-toplevel 2>/dev/null)" || {
    _log_fatal ci-and-stamp precondition_missing path="${target}" reason=not-a-git-repo
    exit 2
  }

  local kind
  kind="$(detect_kind "${root}")"
  if [[ "${kind}" == none ]]; then
    _log_warn ci-and-stamp no_ci_mechanism repo="${root}" reason=no-justfile-no-ci-sh
    return 0
  fi

  local rc
  run_ci "${root}" "${kind}"
  rc=$?

  # Single verdict, single branch -- the two states are mutually
  # exclusive by construction rather than by statement ordering.
  if (( rc != 0 )); then
    _log_err ci-and-stamp ci_failed repo="${root}" rc="${rc}" action=no-stamp
    unstamp "${root}"
    return "${rc}"
  fi

  stamp "${root}" || return 1
  return 0
}

main "$@"
