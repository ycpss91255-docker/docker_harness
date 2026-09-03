#!/usr/bin/env bash
# enforce_ready_for_agent.sh -- Claude Code PreToolUse hook (matcher: Bash)
#
# GATE A of #294: "is this label honest".
#
# Fires before any Bash command. BLOCKS (permissionDecision: deny) a
# `gh issue edit N --add-label ready-for-agent` when the issue does not
# actually carry the four parts ADR-00000015 says the label asserts --
# Seams, First slice, Gate, Bound -- and names the ones that are missing.
#
# The readiness question itself lives in scripts/lib/ready-for-agent.sh
# so that Gate B (scripts/check-ready-for-agent.sh, consumed by #296)
# answers it with the same code. Two copies would drift.
#
# Command parsing goes through scripts/lib/gh-command.sh: establish WHAT
# the command IS before deciding what it contains (CONTEXT.md section 15,
# refs #255 / #276 / #283). An issue body or a chained `echo` quoting
# `gh issue edit --add-label ready-for-agent` is data, not an invocation,
# and must not trigger this gate.
#
# Silent (no verdict) when:
#   - the command does not RUN gh, or runs some other gh subcommand
#   - `--add-label` does not include ready-for-agent (adding any other
#     label, and every --remove-label, is untouched)
#   - the target repo does not define the label at all -- a gate firing
#     where the vocabulary is not adopted is pure friction (#278)
#   - gh cannot answer (not installed, network, auth): never block a
#     label edit on a transient failure
#   - the issue argument names no readable issue (a shell variable, a
#     flag): guessing which issue was meant is worse than not answering
#
# Refs: #294, ADR-00000015 (what the label asserts), ADR-00000014 (the
#       dispatch contract the four parts feed).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HOOK_DIR}/../scripts/lib/gh-command.sh"
# shellcheck disable=SC1091
source "${HOOK_DIR}/../scripts/lib/ready-for-agent.sh"

# adds_label <seg> <label> -- 0 when the segment's --add-label flags
# name <label>. gh accepts both spellings and this must answer for both:
# repeated flags (`--add-label bug --add-label ready-for-agent`) and one
# comma-joined value (`--add-label "bug,ready-for-agent"`).
#
# Whole entry, never substring: `not-ready-for-agent-yet` is a different
# label, and over-matching is exactly the defect #255 / #276 / #283 were.
adds_label() {
  local seg="$1" want="$2" value item
  while IFS= read -r value; do
    local IFS=','
    for item in ${value}; do
      item="${item#"${item%%[![:space:]]*}"}"   # ltrim
      item="${item%"${item##*[![:space:]]}"}"   # rtrim
      [[ "${item}" == "${want}" ]] && return 0
    done
  done < <(gh_flag_values "${seg}" '--add-label')
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
  local input cmd seg ref repo num missing status joined

  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [[ -z "${cmd}" ]] && return 0

  gh_mentions_gh "${cmd}" || return 0
  seg="$(gh_segment "${cmd}")" || return 0
  [[ -z "${seg}" ]] && return 0
  [[ "$(gh_subcommand "${seg}")" == "issue edit" ]] || return 0

  adds_label "${seg}" "${READY_FOR_AGENT_LABEL}" || return 0

  # Resolve the target BEFORE the label lookup: a URL ref names its own
  # repo and overrides any -R on the line, so the inventory must be read
  # from the repo the edit will actually land in.
  ref="$(gh_issue_ref "${seg}" 'edit')" || return 0
  num="${ref%% *}"
  # A bare number comes back with its repo half empty, which command
  # substitution then strips -- so test for the separator, never for an
  # empty tail (`${ref#* }` on a separator-less string returns the whole
  # string, i.e. the number as the repo).
  repo=""
  [[ "${ref}" == *' '* ]] && repo="${ref#* }"
  [[ -z "${repo}" ]] && repo="$(gh_repo_flag "${seg}")"

  # Not adopted here, or gh cannot say -- stay out of the way.
  rfa_label_defined "${repo}" || return 0

  missing="$(rfa_check "${num}" "${repo}")"
  status=$?
  (( status == 0 )) && return 0   # honest label
  (( status != 1 )) && return 0   # undecidable -- fail open

  joined="$(printf '%s' "${missing}" | tr '\n' '|' | sed 's/|$//; s/|/, /g')"
  deny "\`${READY_FOR_AGENT_LABEL}\` asserts four things are present in issue #${num}, and these are missing: ${joined}. The label is a promise to an unattended implementer (ADR-00000015 / ADR-00000014), so it cannot go on until the promise is true. Write the missing part(s) back to the issue as a COMMENT -- the body stays the original spec, evolution goes in comments -- under the fixed headings $(rfa_headings_hint), then re-apply the label. Format: .claude/skills/gh-artifact-format/SKILL.md section 7."
  return 0
}

main "$@"
