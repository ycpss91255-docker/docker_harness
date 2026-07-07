#!/usr/bin/env bash
# enforce_local_full_ci_before_pr.sh -- Claude Code PreToolUse hook
# (matcher: Bash, refs #176).
#
# Blocks `gh pr create` / `gh pr ready` unless local CI has passed on
# the current HEAD -- a marker file `.claude/state/local-ci-pass/<sha>.ok`
# written by the repo's CI target (`make -C .claude/test test` here) on
# green. Two PRs in the base v0.40.0 release reached `gh pr create` with
# code GH CI then rejected, each forcing a rebase + force-push + full
# re-run cycle; this gate catches those locally first.
#
# Decision order:
#   1. `LOCAL_CI_ACK=<sha>` env prefix in the command, value == HEAD ->
#      ALLOW (single-use override; must match the exact HEAD sha).
#   2. Marker for the exact HEAD sha exists -> ALLOW.
#   3. Otherwise, if some marker sha is an ancestor of HEAD AND every
#      path changed since it is doc-only (doc/, *.md, CHANGELOG*,
#      TEST.md, README*) -> ALLOW. This is the common "ran tests green,
#      then committed a CHANGELOG / TEST.md bump" flow -- the tested
#      code did not change, so the green is still valid.
#   4. Else -> DENY with the run-CI / override guidance.
#
# Fail safe: if cwd is missing or not a git repo, stay silent (never
# block on an unresolvable context).
#
# Marker state lives under `.claude/state/` (gitignored, machine-local).

set -uo pipefail

readonly MARKER_SUBDIR=".claude/state/local-ci-pass"

# doc_only_path <path> -- 0 if the path is documentation (changing it
# cannot affect test outcomes), 1 otherwise.
doc_only_path() {
  local p="$1" base
  base="${p##*/}"
  [[ "${p}" == doc/* ]] && return 0
  [[ "${p}" == *.md ]] && return 0
  [[ "${base}" == CHANGELOG* ]] && return 0
  [[ "${base}" == TEST.md ]] && return 0
  [[ "${base}" == README* ]] && return 0
  return 1
}

deny() {
  local reason="$1"
  jq -n --arg m "${reason}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $m
    }
  }'
}

main() {
  local input cmd cwd
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  cwd="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
  [[ -z "${cmd}" ]] && return 0

  # Trigger only on PR-open / PR-ready.
  [[ "${cmd}" =~ gh[[:space:]]+pr[[:space:]]+(create|ready)([[:space:]]|$) ]] || return 0

  # Resolve repo root + HEAD; fail safe (silent) if not a git repo.
  [[ -z "${cwd}" ]] && cwd="${PWD}"
  local root head
  root="$(git -C "${cwd}" rev-parse --show-toplevel 2>/dev/null)" || return 0
  head="$(git -C "${root}" rev-parse HEAD 2>/dev/null)" || return 0

  # Fail-open when the repo has no detectable CI mechanism (refs #208):
  # nothing can write the marker, so there is nothing to gate. The
  # markers are written by ci-and-stamp.sh, which only knows how to run
  # CI for repos carrying one of these (mutually exclusive across the
  # org's repos). A repo with none has no local CI to assert -> allow.
  if [[ ! -x "${root}/.claude/test/ci.sh" \
        && ! -f "${root}/justfile.ci" \
        && ! -f "${root}/justfile" ]]; then
    return 0
  fi

  # 1. LOCAL_CI_ACK override (must match HEAD exactly).
  if [[ "${cmd}" =~ LOCAL_CI_ACK=([0-9a-fA-F]+) ]]; then
    [[ "${BASH_REMATCH[1]}" == "${head}" ]] && return 0
  fi

  local marker_dir="${root}/${MARKER_SUBDIR}"

  # 2. Marker for exact HEAD.
  [[ -f "${marker_dir}/${head}.ok" ]] && return 0

  # 3. Some ancestor marker with only-docs-changed-since.
  local short="${head:0:8}"
  if [[ -d "${marker_dir}" ]]; then
    local f sha
    for f in "${marker_dir}"/*.ok; do
      [[ -e "${f}" ]] || continue
      sha="${f##*/}"; sha="${sha%.ok}"
      git -C "${root}" merge-base --is-ancestor "${sha}" "${head}" 2>/dev/null || continue
      local changed all_doc=1 line
      changed="$(git -C "${root}" diff --name-only "${sha}" "${head}" 2>/dev/null)"
      while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        doc_only_path "${line}" || { all_doc=0; break; }
      done <<< "${changed}"
      (( all_doc )) && return 0
    done
  fi

  # 4. Deny.
  deny "Local CI has not passed on HEAD ${short}. Run \`.claude/scripts/ci-and-stamp.sh\` from the repo (it auto-detects the repo's CI -- make / just / build.sh -- runs the full mirror, and writes ${MARKER_SUBDIR}/<sha>.ok on green). Then re-open the PR. If you have a reason to skip (and accept the GH CI round-trip risk), override for this exact HEAD: LOCAL_CI_ACK=${head} gh pr create ... (refs #176 / #208)."
  return 0
}

main "$@"
