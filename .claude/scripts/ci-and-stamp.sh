#!/usr/bin/env bash
# log-allow:script -- emits data-product output (CI passthrough + next-step / stamp notice) alongside _log_*; per-callsite split deferred until tooling can distinguish.

#
# ci-and-stamp.sh -- run a repo's local CI mirror and, on green, write the
# local-ci-pass marker that enforce_local_full_ci_before_pr.sh checks
# (refs #208 / #176 / #272).
#
# The PR gate (`enforce_local_full_ci_before_pr.sh`) fires for ANY
# repo's worktree but the marker was originally written only by
# docker_harness's own `.claude/test/Makefile`, so base / downstream
# PRs were always denied. This helper centralises marker-writing on the
# docker_harness side: it detects the target repo's CI command, runs the
# mirror, and stamps only on green. The marker convention stays
# entirely here -- base's `justfile.ci` does not carry it.
#
# WHAT THE MARKER MEANS (refs #272). It attests the part of the required set
# this machine actually ran -- NOT "GH CI will pass". It used to claim the
# latter while running `just test && just test lint` against a `ci-rollup`
# that requires thirteen jobs, and one PR went red three times on checks the
# marker had already blessed. So the required set is now DERIVED from the
# repo's own workflow on every run (`lib/ci-required-jobs.sh`), each required
# job is classified `attested` (the mirror really ran it) or `excluded` (it
# did not, with the reason), both lists are written INTO the marker and
# printed at stamp time, and a required job in neither list ABORTS the stamp
# rather than silently widening the gap. Adding a job to `ci-rollup`'s
# `needs:` therefore fails here instead of failing on someone's PR.
#
# Usage:
#   ci-and-stamp.sh [<repo-path>]      # default: cwd
#
# Detection (first match wins; order matters -- both base and downstream
# now carry a root justfile, so the .base/ subtree distinguishes them):
#   <root>/.claude/test/ci.sh         -> docker_harness -> .claude/test/ci.sh check
#   <root>/justfile  +  <root>/.base/ -> downstream      -> just build test
#   <root>/justfile  (no .base/)      -> base            -> actionlint, then
#                                        just test && just test lint
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
# is not a git repo; 3 if a job the repo's CI requires is classified
# neither attested nor excluded (nothing is run and nothing is stamped).
# On a no-CI repo: 0 (nothing to run, nothing to stamp).
#
# Run from the main session (not a subagent) -- subagent sandbox blocks
# docker.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/log.sh disable=SC1091
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/ci-required-jobs.sh disable=SC1091
source "${SCRIPT_DIR}/lib/ci-required-jobs.sh"

readonly MARKER_SUBDIR=".claude/state/local-ci-pass"

# Where each repo flavour declares what its CI requires (repo-root relative).
readonly BASE_WORKFLOW=".github/workflows/self-test.yaml"
readonly HARNESS_WORKFLOW=".github/workflows/test.yaml"

# Required `ci-rollup` jobs the base mirror really runs. Membership is a claim
# about what `actionlint` + `just test` + `just test lint` cover:
#   the lint phase's _LINT_TOOLS entries  -> shellcheck, hadolint, doc-counts
#   the phase's remaining five lints      -> lint-static
#   _run_tests (unit + integration)       -> bats-fragile, bats-integration
#   run_actionlint below, at the pin the workflow declares -> actionlint
# Adding a name here without changing what the mirror runs is the one way to
# make the marker lie again; the excluded table below is the honest way to
# shrink the claim.
readonly _BASE_ATTESTED=(
  actionlint
  shellcheck
  hadolint
  doc-counts
  lint-static
  bats-fragile
  bats-integration
)

# Required jobs the base mirror deliberately does NOT run, as `<job>=<reason>`.
# The reason is written verbatim into the marker, so "excluded" always answers
# "excluded why" where somebody reads the attestation. Cost is the argument for
# four of them: running the kcov matrix, the two-arch acceptance matrix and the
# image-lifecycle gate on every stamp is minutes-to-tens-of-minutes, which
# would get the gate bypassed rather than obeyed.
readonly _BASE_EXCLUDED=(
  "classify=CI-only path classifier computing the other jobs' if: gates; no repo-content verdict exists to reproduce locally"
  "compute-shards=emits the partition the coverage matrix fans out over; the mirror runs that suite unsharded, so no partition is computed and there is nothing here to reproduce (the partitioner's own logic IS covered, by the shard-balance specs)"
  "coverage=kcov shard matrix; these specs DO run here, their kcov instrumentation does not (8-12 min) -- run just test coverage before a release or a shell-heavy PR"
  "coverage-gate=merges the coverage job's shard artifacts, which this run does not produce; COVERAGE_MIN is not modelled at all"
  "acceptance=native amd64 + arm64 runner matrix scaffolding a synthesized downstream repo; there is no local arm64 runner"
  "system=docker.sock image-lifecycle gate; run just test system by hand when the change touches the runtime"
  "worker-selftest=invokes base's reusable build-worker.yaml, which only a GitHub Actions runner can call"
)

# head_sha <root> -- print <root>'s HEAD sha; non-zero if unresolvable.
head_sha() {
  local head
  head="$(git -C "$1" rev-parse HEAD 2>/dev/null)" || return 1
  [[ -n "${head}" ]] || return 1
  printf '%s\n' "${head}"
}

# classify <required> <attested> <excluded-kv> -- all three newline-separated.
# Print one `attested <job>` / `excluded <job> <reason>` line per required job,
# in the order the workflow lists them. When some required job matches neither
# table, emit a final `unclassified <job>...` line and return 1 -- reported in
# the output rather than through a global, because every caller reads this
# through a command substitution and a global set in that subshell would never
# reach them.
classify() {
  local required="$1" attested="$2" excluded_kv="$3"
  local job reason unknown=()
  while IFS= read -r job; do
    [[ -n "${job}" ]] || continue
    if printf '%s\n' "${attested}" | grep -qxF -- "${job}"; then
      printf 'attested %s\n' "${job}"
      continue
    fi
    reason="$(printf '%s\n' "${excluded_kv}" | grep -m1 -- "^${job}=" || true)"
    if [[ -n "${reason}" ]]; then
      printf 'excluded %s %s\n' "${job}" "${reason#*=}"
      continue
    fi
    unknown+=("${job}")
  done <<< "${required}"

  if (( ${#unknown[@]} > 0 )); then
    printf 'unclassified %s\n' "${unknown[*]}"
    return 1
  fi
}

# build_attestation <root> <kind> -- print the marker body: a provenance
# header plus the per-job classification. Returns 1 when a required job is
# unclassified (the caller must then run nothing and stamp nothing).
build_attestation() {
  local root="$1" kind="$2"
  local source_desc="" required="" attested="" excluded_kv="" mirror=""

  case "${kind}" in
    base)
      mirror="actionlint + just test + just test lint"
      required="$(ci_required_jobs "${root}/${BASE_WORKFLOW}" ci-rollup || true)"
      source_desc="${BASE_WORKFLOW} :: ci-rollup needs"
      attested="$(printf '%s\n' "${_BASE_ATTESTED[@]}")"
      # actionlint is only attestable if its pin can be read out of the
      # workflow; if it cannot, drop the claim so the job falls through to
      # "unclassified" and aborts, rather than being attested un-run.
      if ! ci_actionlint_image "${root}/${BASE_WORKFLOW}" > /dev/null; then
        attested="$(printf '%s\n' "${attested}" | grep -vxF actionlint || true)"
      fi
      excluded_kv="$(printf '%s\n' "${_BASE_EXCLUDED[@]}")"
      ;;
    docker_harness)
      mirror=".claude/test/ci.sh check"
      required="$(ci_ci_sh_targets "${root}/${HARNESS_WORKFLOW}" || true)"
      source_desc="${HARNESS_WORKFLOW} :: ci.sh steps"
      # The driver's own `check` target IS the mirror, so what it runs is the
      # attested set -- derived from the driver rather than restated here.
      # `build` joins it because every docker-backed target builds first.
      attested="$(ci_check_targets "${root}/.claude/test/ci.sh" || true)"
      attested="$(printf '%s\nbuild\n' "${attested}")"
      excluded_kv=""
      ;;
    *)
      # downstream: `just build test` against a workflow this script has no
      # aggregator contract for. Say so rather than imply coverage.
      mirror="just build test"
      source_desc="none -- no aggregator contract is derived for this repo flavour"
      ;;
  esac

  local head
  head="$(head_sha "${root}")" || head="unknown"

  printf '# local-ci-pass marker -- .claude/scripts/ci-and-stamp.sh (refs #272)\n'
  printf '# repo    %s\n' "${root}"
  printf '# head    %s\n' "${head}"
  printf '# kind    %s\n' "${kind}"
  printf '# mirror  %s\n' "${mirror}"
  printf '# derived %s\n' "${source_desc}"
  printf '#\n'
  printf '# attested = the mirror really ran that required job. excluded = it\n'
  printf '# did NOT, and the reason follows on the same line. So this marker is\n'
  printf '# permission to open a PR, not a promise that GH CI will pass.\n'

  if [[ -z "${required}" ]]; then
    printf 'derived none\n'
    return 0
  fi
  classify "${required}" "${attested}" "${excluded_kv}"
}

# stamp <root> <body> -- write the green marker for <root>'s HEAD. Returns
# non-zero (and logs) when it cannot, so the caller turns an
# unrecordable green into a red instead of a pass with no attestation.
stamp() {
  local root="$1" body="$2" head
  head="$(head_sha "${root}")" || {
    _log_err ci-and-stamp marker_write_failed repo="${root}" reason=head-unresolvable
    return 1
  }
  local dir="${root}/${MARKER_SUBDIR}"
  if ! mkdir -p "${dir}" 2>/dev/null \
     || ! printf '%s\n' "${body}" > "${dir}/${head}.ok" 2>/dev/null; then
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

# run_actionlint <root> -- mirror the workflow's actionlint job: same image
# pin, same `-ignore` suppressions, both read out of the workflow so a bump in
# CI cannot leave this behind. No actionlint job -> nothing to mirror (0).
run_actionlint() {
  local root="$1"
  local wf="${root}/${BASE_WORKFLOW}" img
  img="$(ci_actionlint_image "${wf}")" || return 0

  local -a args=()
  [[ -t 1 ]] && args+=(-color)
  local pat
  while IFS= read -r pat; do
    [[ -n "${pat}" ]] && args+=(-ignore "${pat}")
  done < <(ci_actionlint_ignores "${wf}")

  _log_info ci-and-stamp ci_start kind=base cmd=actionlint image="${img}"
  docker run --rm -v "${root}:/repo:ro" -w /repo "${img}" "${args[@]}"
}

# run_ci <root> <kind> -- run the local mirror; returns its exit code.
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
      # actionlint first, mirroring the workflow (there it gates the rest, and
      # it is the cheapest of the thirteen -- one container, no image build).
      run_actionlint "${root}" || return $?
      _log_info ci-and-stamp ci_start kind=base cmd="just test && just test lint"
      ( cd "${root}" && just test && just test lint )
      ;;
  esac
}

# report_scope <body> -- print the exclusions to the operator at stamp time.
# The moment somebody learns "stamped" is the moment they must also learn what
# was not run; leaving it in the marker file alone reproduces the original bug
# one indirection further out.
report_scope() {
  local body="$1" excluded
  excluded="$(printf '%s\n' "${body}" | grep '^excluded ' || true)"
  [[ -n "${excluded}" ]] || return 0
  printf 'Stamped. This marker does NOT model these required jobs:\n'
  printf '%s\n' "${excluded}" | sed 's/^excluded /  - /'
  printf 'Open the PR knowing GH CI still has to run them.\n'
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

  # Classify BEFORE running anything: an unclassified required job means the
  # attestation is unsound, and burning the mirror first would only delay the
  # same refusal by ten minutes.
  local attestation unclassified
  attestation="$(build_attestation "${root}" "${kind}")" || {
    unclassified="$(printf '%s\n' "${attestation}" | sed -n 's/^unclassified //p')"
    _log_fatal ci-and-stamp required_jobs_unclassified repo="${root}" \
      kind="${kind}" jobs="${unclassified}"
    printf 'CI requires job(s) this mirror neither runs nor excludes: %s\n' \
      "${unclassified}" >&2
    printf 'Teach .claude/scripts/ci-and-stamp.sh about them -- _BASE_ATTESTED if the mirror covers it, _BASE_EXCLUDED with a reason if it cannot -- then re-run.\n' >&2
    return 3
  }

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

  stamp "${root}" "${attestation}" || return 1
  report_scope "${attestation}"
  return 0
}

main "$@"
