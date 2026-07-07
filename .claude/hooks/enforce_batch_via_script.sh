#!/usr/bin/env bash
# enforce_batch_via_script.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# DENIES ad-hoc cross-repo for-loops that perform state-changing operations.
# CLAUDE.md "Cross-repo batch mutation" rule: any loop iterating over a list
# of repos / PRs / issues and performing mutation must go through a
# permanent `.claude/scripts/<name>.sh` (or the slash command that wraps
# it). Reason: N-iteration loop creates N user prompts, induces yes-fatigue,
# and effectively bypasses every ask rule downstream.
#
# Detection (both clauses must hold in the same command string):
#   1. for-loop signature: `for\s+<var>\s+in\s+...` (single or multi-line)
#   2. mutating ops anywhere in the same command:
#        git\s+(push|reset|tag|branch\s+-D)   (mutating git verbs;
#                                              `git tag -d` delete excluded)
#        gh\s+(issue|pr)\s+(close|merge)
#        gh\s+(issue|pr)\s+comment\s+(.+\s)?--body
#
# Pass-through silent when:
#   - no for-loop signature
#   - loop body is read-only (gh pr view, git log, grep, cat, find, ...)
#   - command starts with `.claude/scripts/` (permanent batch wrapper -- the
#     point of this hook is to nudge the agent TOWARD these)
#   - empty command
#
# Lift mechanism: the `/tmp` checkpoint protocol (ADR-00000002 / #117).
# On deny, write a five-section checkpoint via write_checkpoint and quote
# the matching `touch <ack>` command. A second attempt of the same cmd
# (sha256(cmd)-16hex hash) hits is_acked and is allowed through.
#
# Refs: issue #121 (this hook), #117 (checkpoint helper), #116 Tier 2.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HOOK_DIR}/../scripts/lib/checkpoint.sh"

readonly HOOK_SLUG="enforce-batch-via-script"
readonly REASON='Inline cross-repo for-loops with state-changing operations create N user prompts (yes-fatigue) and bypass every ask rule downstream.'
readonly CANONICAL='Write or reuse a permanent .claude/scripts/<name>.sh (one prompt for the whole batch). Examples: .claude/scripts/batch-pr-merge.sh, batch-base-upgrade.sh, batch-open-archive-rename-issues.sh.'

main() {
  local input cmd
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [[ -z "${cmd}" ]] && return 0

  # Skip permanent batch wrappers -- the point of this hook is to nudge
  # the agent toward these.
  if [[ "${cmd}" =~ (^|[[:space:]])\.?\.?/?\.claude/scripts/ ]]; then
    return 0
  fi

  # Clause 1: for-loop signature.
  [[ "${cmd}" =~ (^|[[:space:]\;\&\|])for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]] ]] || return 0

  # Clause 2: mutating ops. Order matters -- gh comment --body is the
  # multi-word pattern, so check via grep -E for clarity.
  local matched=0
  if printf '%s' "${cmd}" | grep -qE 'git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*(push|reset|branch[[:space:]]+-D)([[:space:]]|$)'; then
    matched=1
  elif printf '%s' "${cmd}" | grep -qE 'git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*tag[[:space:]]+([^-d]|-[A-Za-cefg-z])'; then
    # git tag <name> or git tag -a/-s/-m ... (create). Exclude `git tag -d`.
    matched=1
  elif printf '%s' "${cmd}" | grep -qE 'gh[[:space:]]+(issue|pr)[[:space:]]+(close|merge)([[:space:]]|$)'; then
    matched=1
  elif printf '%s' "${cmd}" | grep -qE 'gh[[:space:]]+(issue|pr)[[:space:]]+comment[[:space:]].+--body([[:space:]]|=)'; then
    matched=1
  fi

  (( matched )) || return 0

  # Ack short-circuit.
  local ack_path
  if ack_path="$(is_acked "${HOOK_SLUG}" "${cmd}")"; then
    jq -n --arg p "${ack_path}" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        permissionDecisionReason: ("user previously acked via " + $p)
      }
    }'
    return 0
  fi

  local md_path
  md_path="$(write_checkpoint \
    "${HOOK_SLUG}" \
    "${cmd}" \
    "${REASON}" \
    "${CANONICAL}" \
    "See CLAUDE.md > 跨 repo 批次 mutation 規範 (cross-repo batch mutation rule) for the full rule.")"

  local deny_msg
  deny_msg="batch-via-script gate (CLAUDE.md cross-repo mutation): inline for-loop with mutating git/gh operations is denied.
${CANONICAL}
Why: ${REASON}
Checkpoint written to:
  ${md_path}
If you really want to run the original command, touch the matching ack
file (see section 4 of the checkpoint), then re-issue the same command.
The companion auto_allow_touch_ack.sh hook allows the ack touch."

  jq -n --arg m "${deny_msg}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $m
    }
  }'

  return 0
}

main "$@"
