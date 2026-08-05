#!/usr/bin/env bash
# ci-required-jobs.sh -- derive what a repo's CI actually requires, from the
# repo's own workflow, so a local "CI mirror" can be checked against it
# instead of trusting a hand-kept list (refs #272).
#
# The failure this exists to prevent: `ci-and-stamp.sh` writes a marker that
# `enforce_local_full_ci_before_pr.sh` turns into permission to open a PR, and
# that marker was read as "GH CI will pass". It attested `just test && just
# test lint` while `ci-rollup` required thirteen jobs -- and nothing compared
# the two, so a required job that the mirror never ran could (and did) fail on
# an already-blessed branch. A hand-written "these are the required jobs" table
# would have the same rot; the set has to be READ OUT of the workflow every
# run. Same shape as base's `lint-static` completeness guard, which parses
# `_LINT_TOOLS` rather than restating it.
#
# Source, do not execute. Functions:
#   ci_required_jobs <workflow> [<rollup-job>]
#   ci_ci_sh_targets <workflow>
#   ci_check_targets <ci-sh>
#   ci_actionlint_image <workflow>
#   ci_actionlint_ignores <workflow>
#
# Every function is a pure reader: no mutation, no network, output on stdout,
# non-zero + silence when the thing being derived is not present (the caller
# decides whether absence is fatal).

# ci_required_jobs <workflow> [<rollup-job>] -- print, one per line, the jobs
# the aggregator job (default `ci-rollup`) lists in its `needs:`. That list is
# the definition of "required" under a single-aggregator branch protection:
# joining it is what makes a job block a merge.
#
# Both YAML sequence forms are accepted -- flow (`needs: [a, b]`, what base
# writes) and block (`needs:` + `- a` lines) -- because which one a future edit
# uses is not something this reader should get to dictate.
#
# Returns 1 (silently) when the workflow or the job is absent.
ci_required_jobs() {
  local wf="$1" job="${2:-ci-rollup}"
  [[ -f "${wf}" ]] || return 1

  local raw
  raw="$(awk -v want="  ${job}:" '
    $0 == want            { in_job = 1; next }
    in_job && /^[^[:space:]]/   { exit }
    in_job && /^  [^[:space:]]/ { exit }
    in_job && /^    needs:/     { in_needs = 1; print; next }
    in_needs && /^      - /     { print; next }
    in_needs                    { exit }
  ' "${wf}")" || return 1
  [[ -n "${raw}" ]] || return 1

  printf '%s\n' "${raw}" | awk '
    {
      sub(/^[[:space:]]*needs:[[:space:]]*/, "")
      sub(/^[[:space:]]*-[[:space:]]*/, "")
      gsub(/[][,"'"'"']/, " ")
      n = split($0, a, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
    }
  '
}

# ci_ci_sh_targets <workflow> -- print, one per line, the `ci.sh` targets the
# workflow invokes as steps. docker_harness has no aggregator job to read: its
# workflow enumerates the driver's targets one step at a time (deliberately, so
# a target added to the local gate alone gates nothing on a PR and is visible
# as such). That enumeration is the required set for that repo.
#
# Returns 1 (silently) when the workflow is absent or names no target.
ci_ci_sh_targets() {
  local wf="$1"
  [[ -f "${wf}" ]] || return 1
  local out
  out="$(grep -oE '(^|[[:space:]])\./ci\.sh[[:space:]]+[a-z][a-z-]*' "${wf}" \
         | awk '{ print $NF }' | sort -u)"
  [[ -n "${out}" ]] || return 1
  printf '%s\n' "${out}"
}

# ci_check_targets <ci-sh> -- print, one per line, the targets the driver's
# aggregate `check` target runs, derived from the `t_check()` body. Underscores
# in the function names map back to the hyphens of the target names
# (`t_doc_count_check` -> `doc-count-check`), which is the driver's own naming
# convention rather than an assumption made here.
#
# Returns 1 (silently) when the driver or its `t_check` is absent.
ci_check_targets() {
  local sh="$1"
  [[ -f "${sh}" ]] || return 1
  local out
  out="$(awk '
    /^t_check\(\)/ { in_check = 1; next }
    in_check && /^}/ { exit }
    in_check && /^[[:space:]]*t_[a-z_]+$/ {
      gsub(/[[:space:]]/, "")
      sub(/^t_/, "")
      gsub(/_/, "-")
      print
    }
  ' "${sh}")"
  [[ -n "${out}" ]] || return 1
  printf '%s\n' "${out}"
}

# ci_actionlint_image <workflow> -- print the pinned actionlint image the
# workflow runs. Derived rather than restated so a version bump in CI cannot
# leave a local mirror lagging on an older rule set (which is exactly how a
# floating-versus-pinned linter turns a green local run into a red PR).
#
# Returns 1 (silently) when the workflow does not run actionlint.
ci_actionlint_image() {
  local wf="$1"
  [[ -f "${wf}" ]] || return 1
  local img
  img="$(grep -oE 'rhysd/actionlint:[A-Za-z0-9._-]+' "${wf}" | head -n1)"
  [[ -n "${img}" ]] || return 1
  printf '%s\n' "${img}"
}

# ci_actionlint_ignores <workflow> -- print each `-ignore '<regex>'` argument
# the workflow passes to actionlint, one per line. Without them a local run
# reports the known false positives CI suppresses, and a mirror that cries wolf
# gets ignored -- which is a slower version of not running it at all.
#
# Returns 0 with no output when there are none (absence is not an error here).
ci_actionlint_ignores() {
  local wf="$1"
  [[ -f "${wf}" ]] || return 0
  sed -n "s/.*-ignore[[:space:]]*'\\([^']*\\)'.*/\\1/p" "${wf}"
}
