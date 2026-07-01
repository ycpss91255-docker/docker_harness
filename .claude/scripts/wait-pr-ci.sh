#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

# wait-pr-ci.sh — poll GitHub PR CI rollup until all PRs settle.
#
# Designed to be wrapped in a single Monitor call from the wait-pr-ci
# skill. Extracting the loop here keeps the Monitor body to one line so
# Claude Code's bash AST parser does not emit `Contains simple_expansion`
# warnings on parameter expansions like ${pair%:*}.
#
# Usage:
#   wait-pr-ci.sh --repo <OWNER>/<REPO> --prs <N1,N2,...> [options]
#
# Options:
#   --repo <OWNER>/<REPO>     GitHub repo (required)
#   --prs <CSV>               Comma-separated PR numbers (required)
#   --check-filter <jq-expr>  jq inner expression filtering
#                             .statusCheckRollup[]?. Default:
#                             '.name=="test" or (.name|startswith("Integration"))'
#   --min-checks <N>          Minimum number of filter-matched checks
#                             required before "all-pass" is allowed.
#                             Default 1 (backwards-compatible). Set to the
#                             count of required-check names the workflow
#                             ought to register to guard against GitHub's
#                             PR rollup briefly returning a SUBSET of
#                             expected checks right after PR creation
#                             (e.g. for the default filter `test +
#                             Integration ...` use --min-checks 2). When
#                             length < N the state is "pending", not
#                             "all-pass".
#   --interval <seconds>      Poll interval (default 45; 0 = no sleep, for tests)
#
# Stale-rollup guards (refs ycpss91255-docker/docker_harness#60):
#   * Watch-start completedAt guard — if every filter-matched check has
#     completedAt < <watch start>, the rollup is showing carry-over
#     results from a previous head (typically because the agent ran this
#     script immediately after a `git push --force-with-lease` and GitHub
#     has not yet re-triggered CI). Demoted to "pending" rather than
#     declared "all-pass". Backwards-compatible: only fires when every
#     matching check has completedAt set (real GitHub API always sets
#     it; existing test stubs that omit it keep working).
#   * headRefOid change guard — on each poll, compare current
#     headRefOid against the value seen on the previous poll. When it
#     changes, emit one `[head-moved] PR<n> <old7>..<new7>` log line and
#     force the per-PR state to "pending" for this poll iteration. The
#     next poll re-evaluates against the new head normally.
#   --max-iterations <N>      Iteration cap (default 0 = unlimited; for tests)
#   -h, --help                Show this help
#
# Exit:
#   0   = ALL_DONE — every PR is all-pass + MERGEABLE
#   1   = FAIL     — any required check went FAILURE
#   2   = arg error
#   124 = max-iterations exhausted without resolution
#
# Output (per state transition):
#   PR<n>: checks=<state> mergeable=<m>
#   ...
#   ---
# Final line: `ALL_DONE` or `FAIL <pr>`.

set -euo pipefail

_WPC_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=lib/log.sh disable=SC1091
source "${_WPC_SCRIPT_DIR}/lib/log.sh"

readonly DEFAULT_FILTER='.name=="test" or (.name|startswith("Integration"))'

# _emit_event <exit_reason> <repo> <prs_csv> <iter> <watch_start> <head_moves>
#
# Append one JSON event line to ~/.claude/log/wait-pr-ci-events.log on
# every terminal exit (refs #175 Phase 1). The log accumulates across
# sessions so Phase 2 can classify "Monitor stuck" failure modes.
# Non-fatal: mkdir / append errors are swallowed so a broken log file
# never blocks the script's primary work.
_emit_event() {
  local exit_reason="$1" repo="$2" prs_csv="$3" iter="$4" watch_start="$5" head_moves="$6"
  local log_dir="${HOME}/.claude/log"
  mkdir -p "${log_dir}" 2>/dev/null || return 0
  local ts elapsed prs_json
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  elapsed=$(( $(date -u +%s) - watch_start ))
  prs_json="$(jq -cnR --arg csv "${prs_csv}" '$csv | split(",") | map(tonumber)' 2>/dev/null || printf '[]')"
  # Subshell isolates the >> redirection so bash's own EISDIR / EACCES
  # error message (printed by the parent shell BEFORE printf runs) is
  # captured by the outer 2>/dev/null. `|| true` then swallows the
  # non-zero exit so set -e never trips on the emit path.
  ( printf '{"ts":"%s","script":"wait-pr-ci.sh","repo":"%s","prs":%s,"exit_reason":"%s","iterations":%d,"elapsed_sec":%d,"head_moves":%d}\n' \
      "${ts}" "${repo}" "${prs_json}" "${exit_reason}" "${iter}" "${elapsed}" "${head_moves}" \
      >> "${log_dir}/wait-pr-ci-events.log" ) 2>/dev/null || true
}

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

main() {
  local repo=""
  local prs_csv=""
  local check_filter="${DEFAULT_FILTER}"
  local min_checks=1
  local interval=45
  local max_iter=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --repo) repo="$2"; shift 2 ;;
      --prs) prs_csv="$2"; shift 2 ;;
      --check-filter) check_filter="$2"; shift 2 ;;
      --min-checks) min_checks="$2"; shift 2 ;;
      --interval) interval="$2"; shift 2 ;;
      --max-iterations) max_iter="$2"; shift 2 ;;
      *) _log_fatal wait-pr-ci unrecognised_arg arg="${1}"; usage; exit 2 ;;
    esac
  done

  if ! [[ "${min_checks}" =~ ^[0-9]+$ ]] || (( min_checks < 1 )); then
    _log_fatal wait-pr-ci precondition_missing arg=--min-checks value="${min_checks}" reason=not-positive-integer
    exit 2
  fi

  if [[ -z "${repo}" ]]; then
    _log_fatal wait-pr-ci precondition_missing arg=--repo
    exit 2
  fi
  if [[ -z "${prs_csv}" ]]; then
    _log_fatal wait-pr-ci precondition_missing arg=--prs
    exit 2
  fi

  local -a prs
  IFS=',' read -ra prs <<< "${prs_csv}"

  local watch_start
  watch_start=$(date -u +%s)

  local head_moves_total=0
  local -A head_oid_by_pr=()

  local prev=""
  local iter=0
  while true; do
    iter=$((iter + 1))

    local out=""
    local all_ready=1
    local fail_pr="" fail_reason=""

    local pr
    for pr in "${prs[@]}"; do
      local s
      s=$(gh pr view "${pr}" --repo "${repo}" \
            --json mergeable,statusCheckRollup,headRefOid,state 2>/dev/null \
          || echo '{}')

      # headRefOid stale-rollup guard. Compare PR head against the
      # value seen on the previous poll; on change, emit one
      # `[head-moved] PR<n> <old7>..<new7>` log line so the operator
      # knows the CI signal needs to be re-evaluated against the new
      # head. head_moved is checked below so the all-pass demotion
      # cannot fire on the same iteration as a head move.
      local current_oid prev_oid head_moved=0
      current_oid=$(jq -r '.headRefOid // ""' <<< "${s}")
      prev_oid="${head_oid_by_pr[${pr}]:-}"
      if [[ -n "${prev_oid}" && -n "${current_oid}" \
            && "${current_oid}" != "${prev_oid}" ]]; then
        head_moved=1
        head_moves_total=$((head_moves_total + 1))
        printf '[head-moved] PR%s %s..%s\n' \
          "${pr}" "${prev_oid:0:7}" "${current_oid:0:7}"
      fi
      head_oid_by_pr["${pr}"]="${current_oid}"

      # Terminal-state short circuit (refs #113). After `gh pr merge
      # --auto` fires, GitHub stops recomputing `mergeable`, leaving it
      # stuck at UNKNOWN. The .state field is authoritative: MERGED is
      # done; CLOSED without merge is a failure. Skip the rest of the
      # rollup parsing for this PR once state is terminal. Absent .state
      # (e.g. legacy mocks) falls through to the existing machinery.
      local pr_state
      pr_state=$(jq -r '.state // "?"' <<< "${s}")
      case "${pr_state}" in
        MERGED)
          out="${out}PR${pr}: state=MERGED (auto-merge completed)"$'\n'
          continue
          ;;
        CLOSED)
          out="${out}PR${pr}: state=CLOSED without merge"$'\n'
          fail_pr="${pr}"
          fail_reason="closed"
          all_ready=0
          continue
          ;;
      esac

      # Two guards above the original `all(.conclusion == "SUCCESS")` to fix
      # premature ALL_DONE seen in practice (refs ycpss91255-docker/docker_harness#XX):
      #
      #  (a) `length < min_checks`  — GitHub's PR rollup briefly returns a
      #      SUBSET of expected checks right after PR creation; if all visible
      #      ones happen to be SUCCESS, jq's `all([SUCCESS]) == true` reports
      #      false all-pass. Caller passes --min-checks to assert the
      #      filter-matched count.
      #  (b) `any(.status != "COMPLETED")` — when a check is registered but
      #      still IN_PROGRESS / QUEUED, .conclusion is "" so the original
      #      `all(.conclusion == "SUCCESS")` correctly reports false; but
      #      this guard catches the same case earlier and produces a more
      #      meaningful "pending" label. The `.status != null` precondition
      #      preserves backward compatibility with mocks that only set
      #      .conclusion (real GitHub API always populates .status).
      # The watch-start completedAt guard is appended inside the
      # all(.conclusion == "SUCCESS") branch: if every matching check
      # has completedAt set AND every one of those completedAt values
      # is older than the watch start time, the rollup is carry-over
      # from a prior head; demote to "pending". The
      # `all(.completedAt != null)` precondition keeps mocks that omit
      # completedAt working unchanged.
      local state
      state=$(jq -r --argjson min "${min_checks}" \
        --argjson watch_start "${watch_start}" \
        "[.statusCheckRollup[]? | select(${check_filter})] as \$c | \
        if (\$c | length) == 0 then \"no-checks\" \
        elif (\$c | length) < \$min then \"pending\" \
        elif (\$c | any(.status != null and .status != \"COMPLETED\")) then \"pending\" \
        elif (\$c | all(.conclusion == \"SUCCESS\" or .conclusion == \"SKIPPED\")) then \
          (if (\$c | all(.completedAt != null)) \
              and (\$c | all((.completedAt | fromdateiso8601) < \$watch_start)) \
           then \"pending\" else \"all-pass\" end) \
        elif (\$c | any(.conclusion == \"FAILURE\")) then \"FAIL\" \
        else \"pending\" end" <<< "${s}")

      if (( head_moved )) && [[ "${state}" == "all-pass" ]]; then
        state="pending"
      fi

      local m
      m=$(jq -r '.mergeable // "?"' <<< "${s}")

      out="${out}PR${pr}: checks=${state} mergeable=${m}"$'\n'

      # mergeable=CONFLICTING means main moved + the PR has merge conflicts.
      # No amount of polling will resolve this -- the head must merge in
      # origin/main. Surface as FAIL with an update-stale-pr.sh hint so the
      # caller acts on it (refs #87 / #221) rather than looping forever.
      case "${state}" in
        FAIL) fail_pr="${pr}"; fail_reason="check"; all_ready=0 ;;
        all-pass)
          case "${m}" in
            MERGEABLE) : ;;
            CONFLICTING) fail_pr="${pr}"; fail_reason="conflict"; all_ready=0 ;;
            *) all_ready=0 ;;
          esac
          ;;
        *) all_ready=0 ;;
      esac
    done

    case "${out}" in
      "${prev}") : ;;
      *) printf '%s---\n' "${out}" ;;
    esac
    prev="${out}"

    if [[ -n "${fail_pr}" ]]; then
      case "${fail_reason:-}" in
        conflict)
          printf 'FAIL %s (mergeable=CONFLICTING). Update (merge origin/main, no rebase):\n  .claude/scripts/update-stale-pr.sh %s --repo %s\nSee .claude/skills/update-stale-pr/SKILL.md.\n' \
            "${fail_pr}" "${fail_pr}" "${repo}"
          ;;
        closed)
          printf 'FAIL %s (state=CLOSED without merge)\n' "${fail_pr}"
          ;;
        *)
          printf 'FAIL %s\n' "${fail_pr}"
          ;;
      esac
      _emit_event FAIL "${repo}" "${prs_csv}" "${iter}" "${watch_start}" "${head_moves_total}"
      exit 1
    fi

    if (( all_ready )); then
      _emit_event ALL_DONE "${repo}" "${prs_csv}" "${iter}" "${watch_start}" "${head_moves_total}"
      echo "ALL_DONE"
      exit 0
    fi

    if (( max_iter > 0 && iter >= max_iter )); then
      _log_err wait-pr-ci wait_failed reason=max-iterations max="${max_iter}"
      _emit_event timeout_max_iter "${repo}" "${prs_csv}" "${iter}" "${watch_start}" "${head_moves_total}"
      exit 124
    fi

    if (( interval > 0 )); then
      sleep "${interval}"
    fi
  done
}

main "$@"
