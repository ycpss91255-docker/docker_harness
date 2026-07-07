#!/usr/bin/env bash
# remind_proactive_optimization.sh -- Claude Code Stop hook.
#
# Fires when Claude's response finishes. Reads the session transcript;
# if the session hit a "task boundary" (a `gh pr merge` was invoked OR
# the total tool-call count reached a threshold) AND the session did
# NOT already mention any optimisation-candidate category, emits a
# non-blocking nudge pointing at the proactive-optimization skill.
#
# Non-blocking. Cannot raise the optimisation candidate itself (hook
# output schema does not support that). Throttled once-per-session per
# signal-set via a TMPDIR marker, matching `remind_strategic_compact.sh`
# and `remind_adr_on_design_decision.sh`.
#
# Why: CLAUDE.md "## 主動優化建議" (Proactive optimisation) requires the
# agent to surface
# optimisation candidates (workflow ergonomics / cross-repo inconsistency
# / doc drift / manual repetition) at task wrap-up. The rule fires
# inconsistently today because there is no enforcement layer. This Stop
# hook is the boundary-triggered reminder. Refs issue
# ycpss91255-docker/docker_harness#124.
#
# Heuristics:
#   Task boundary -- ANY of:
#     - gh pr merge invoked at least once this session, OR
#     - tool-call count >= PROACTIVE_OPTIMIZATION_REMIND_THRESHOLD
#       (default 50)
#   Already mentioned -- text content (user OR assistant) matches the
#     optimisation-candidate regex below (case-insensitive). If so,
#     stay silent -- the candidate was raised in the conversation.
#
# Configuration via env vars:
#   PROACTIVE_OPTIMIZATION_REMIND_THRESHOLD  (default 50)
#   PROACTIVE_OPTIMIZATION_REMIND_DISABLE    (set to 1 to disable)

set -uo pipefail

readonly DEFAULT_TOOL_THRESHOLD=50
readonly TMP_DIR="${TMPDIR:-/tmp}"

# Optimisation-candidate regex. Broad on purpose -- the false-positive
# case (silent when there was a mention but it was not really proposing
# an optimisation) is cheaper than false-negative (nag the user when
# they already discussed it). Case-insensitive via jq's `test(...; "i")`.
readonly OPTIMIZATION_MENTION_REGEX='optimi[sz]ation|optimi[sz]e|automat(e|ion)|scripted|skill candidate|skill[- ]?ify|skill 化|DRY (this|that|it|principle)|redundant step|manual repetition|workflow gap|cross[- ]repo (drift|inconsistency)|propose .*follow[- ]up|raise.*as.*candidate'

main() {
  local input transcript_path session_id stop_active
  input="$(cat)"

  if [[ "${PROACTIVE_OPTIMIZATION_REMIND_DISABLE:-0}" == "1" ]]; then
    return 0
  fi

  transcript_path="$(printf '%s' "${input}" | jq -r '.transcript_path // empty' 2>/dev/null)"
  session_id="$(printf '%s' "${input}" | jq -r '.session_id // empty' 2>/dev/null)"
  stop_active="$(printf '%s' "${input}" | jq -r '.stop_hook_active // false' 2>/dev/null)"

  [[ "${stop_active}" == "true" ]] && return 0
  [[ -z "${transcript_path}" || ! -r "${transcript_path}" ]] && return 0

  local tool_count pr_merge_count
  tool_count="$(jq -s '
      [
        .[]
        | select(.message?.role == "assistant")
        | .message.content[]?
        | select(.type == "tool_use")
      ] | length
    ' "${transcript_path}" 2>/dev/null || echo 0)"
  pr_merge_count="$(jq -s '
      [
        .[]
        | select(.message?.role == "assistant")
        | .message.content[]?
        | select(.type == "tool_use" and .name == "Bash")
        | .input.command // ""
        | select(test("gh[[:space:]]+pr[[:space:]]+merge"))
      ] | length
    ' "${transcript_path}" 2>/dev/null || echo 0)"

  [[ "${tool_count}" =~ ^[0-9]+$ ]] || tool_count=0
  [[ "${pr_merge_count}" =~ ^[0-9]+$ ]] || pr_merge_count=0

  local threshold="${PROACTIVE_OPTIMIZATION_REMIND_THRESHOLD:-${DEFAULT_TOOL_THRESHOLD}}"
  [[ "${threshold}" =~ ^[0-9]+$ ]] || threshold="${DEFAULT_TOOL_THRESHOLD}"

  local -a reasons=()
  if (( pr_merge_count > 0 )); then
    reasons+=("gh pr merge invoked ${pr_merge_count} time(s)")
  fi
  if (( tool_count >= threshold )); then
    reasons+=("tool-call count ${tool_count} >= threshold ${threshold}")
  fi

  (( ${#reasons[@]} == 0 )) && return 0

  # Did the session already mention an optimisation candidate?
  local optimisation_mentions
  optimisation_mentions="$(jq -s --arg p "${OPTIMIZATION_MENTION_REGEX}" '
      [
        .[]
        | select(.message?.role == "user" or .message?.role == "assistant")
        | .message.content
        | if type == "string" then
            select(test($p; "i"))
          elif type == "array" then
            .[] | select(.type? == "text") | .text | select(test($p; "i"))
          else
            empty
          end
      ] | length
    ' "${transcript_path}" 2>/dev/null || echo 0)"

  [[ "${optimisation_mentions}" =~ ^[0-9]+$ ]] || optimisation_mentions=0

  if (( optimisation_mentions > 0 )); then
    return 0
  fi

  # Throttle: once per session per signal-set. Bucket tool_count by /25
  # so a single session does not nag on every Stop event.
  local signal_hash marker_path
  signal_hash="$(printf '%s|%s' "${pr_merge_count}" "$((tool_count / 25))" | md5sum | cut -d' ' -f1)"
  marker_path="${TMP_DIR}/claude-proactive-optimization-${session_id:-anon}-${signal_hash}"
  if [[ -f "${marker_path}" ]]; then
    return 0
  fi
  : > "${marker_path}" 2>/dev/null || true

  local reasons_md=""
  local r
  for r in "${reasons[@]}"; do
    reasons_md+="
  - ${r}"
  done

  local msg
  msg="$(printf 'Proactive-optimisation reminder: this session hit a task boundary but no optimisation candidate was raised.\nSignals:%s\nIf you noticed any of: clunky workflow, cross-repo inconsistency, doc drift, or manual steps repeated 3+ times this session, surface it now as a one-paragraph offer (not a unilateral fix).\nSee .claude/skills/proactive-optimization/SKILL.md for the four candidate categories and the offer phrasing.\nSet PROACTIVE_OPTIMIZATION_REMIND_DISABLE=1 to silence.' \
    "${reasons_md}")"

  # Stop event JSON: top-level systemMessage only.
  jq -n --arg m "${msg}" '{systemMessage: $m}'
  return 0
}

main "$@"
