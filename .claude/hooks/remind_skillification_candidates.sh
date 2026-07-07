#!/usr/bin/env bash
# remind_skillification_candidates.sh -- Claude Code Stop hook.
#
# Fires when Claude's response finishes. Reads the session transcript;
# if the session has any auto-detectable skillification signal (an
# ad-hoc /tmp/*.sh invoked >= threshold times, OR a parser-fallback
# Bash pattern repeated >= threshold times) AND the session did NOT
# already raise a skillification candidate, emits a non-blocking nudge
# pointing at the skillification-candidates skill.
#
# Non-blocking. Cannot promote the candidate itself (hook output schema
# does not support that). Throttled once per session per signal-set via
# a TMPDIR marker, matching `remind_strategic_compact.sh`,
# `remind_adr_on_design_decision.sh`, and
# `remind_proactive_optimization.sh`.
#
# Why: CLAUDE.md "## 主動優化建議 > 任務結束時主動列 skill 化候選"
# (Proactive optimisation > proactively list skillification candidates at
# task end) requires
# the agent to surface skillification candidates (permanent script /
# slash command / skill follow-up) at task wrap-up. The rule fires
# inconsistently today because there is no enforcement layer. Refs
# issue ycpss91255-docker/docker_harness#125.
#
# Auto-detectable signals (the hook covers these):
#   A. /tmp/*.sh invocations -- count Bash commands that mention a path
#      under /tmp/ ending in .sh. Threshold default 3.
#   B. parser-fallback patterns -- count Bash commands matching any of:
#        - heredoc redirect: <<EOF >, <<'EOF' >, <<-EOF >
#        - simple_expansion in command: ${var%:*}, ${var#*}, etc.
#        - herestring: <<<
#        - cd path && git/...: cd \S+ && \w+
#        - subshell-then-tool: (cd path && ...)
#      Threshold default 3.
# Categories 3 (slash-command gap) and 4 (bug in existing skill) are
# NOT auto-detected -- they need semantic understanding and are covered
# by the skill body so the agent surfaces them when it spots them.
#
# Already-raised suppression: scan user + assistant text for a
# skillification-mention regex; if any hit, stay silent.
#
# Configuration via env vars:
#   SKILLIFICATION_TMP_THRESHOLD     (default 3)
#   SKILLIFICATION_PARSER_THRESHOLD  (default 3)
#   SKILLIFICATION_REMIND_DISABLE    (set to 1 to disable)

set -uo pipefail

readonly DEFAULT_TMP_THRESHOLD=3
readonly DEFAULT_PARSER_THRESHOLD=3
readonly TMP_DIR="${TMPDIR:-/tmp}"

# Parser-fallback patterns (POSIX ERE, joined by |). Each alternative
# targets one of the patterns documented in CLAUDE.md's "Bash 命令寫法
# 的 parser 限制" (Bash command-writing parser limitations) table. Tested
# against the .input.command string of
# each Bash tool_use.
readonly PARSER_FALLBACK_PATTERNS='<<[A-Z0-9_]+ *>|<<'\''[A-Z0-9_]+'\'' *>|<<-[A-Z0-9_]+ *>|\$\{[A-Za-z_][A-Za-z0-9_]*%[^}]+\}|\$\{[A-Za-z_][A-Za-z0-9_]*#[^}]+\}|<<<|cd [^&;|]+ && (git|gh|make|\./[a-z]+\.sh)|\(cd [^&;|)]+ && '

# Already-raised suppression regex. Case-insensitive; matched against
# user + assistant text content.
readonly SKILLIFICATION_MENTION_REGEX='skill[- ]?ify|skill 化|skillification|promote .*to .*\.claude/scripts|propose .*\.claude/scripts/|follow[- ]?up issue.*skill|new slash command|workflow gap'

main() {
  local input transcript_path session_id stop_active
  input="$(cat)"

  if [[ "${SKILLIFICATION_REMIND_DISABLE:-0}" == "1" ]]; then
    return 0
  fi

  transcript_path="$(printf '%s' "${input}" | jq -r '.transcript_path // empty' 2>/dev/null)"
  session_id="$(printf '%s' "${input}" | jq -r '.session_id // empty' 2>/dev/null)"
  stop_active="$(printf '%s' "${input}" | jq -r '.stop_hook_active // false' 2>/dev/null)"

  [[ "${stop_active}" == "true" ]] && return 0
  [[ -z "${transcript_path}" || ! -r "${transcript_path}" ]] && return 0

  local tmp_count parser_count
  tmp_count="$(jq -s '
      [
        .[]
        | select(.message?.role == "assistant")
        | .message.content[]?
        | select(.type == "tool_use" and .name == "Bash")
        | .input.command // ""
        | select(test("(^|[[:space:]\\;\\&\\|])/tmp/[^[:space:]]+\\.sh([[:space:]]|$)"))
      ] | length
    ' "${transcript_path}" 2>/dev/null || echo 0)"
  parser_count="$(jq -s --arg p "${PARSER_FALLBACK_PATTERNS}" '
      [
        .[]
        | select(.message?.role == "assistant")
        | .message.content[]?
        | select(.type == "tool_use" and .name == "Bash")
        | .input.command // ""
        | select(test($p))
      ] | length
    ' "${transcript_path}" 2>/dev/null || echo 0)"

  [[ "${tmp_count}" =~ ^[0-9]+$ ]] || tmp_count=0
  [[ "${parser_count}" =~ ^[0-9]+$ ]] || parser_count=0

  local tmp_threshold="${SKILLIFICATION_TMP_THRESHOLD:-${DEFAULT_TMP_THRESHOLD}}"
  local parser_threshold="${SKILLIFICATION_PARSER_THRESHOLD:-${DEFAULT_PARSER_THRESHOLD}}"
  [[ "${tmp_threshold}" =~ ^[0-9]+$ ]] || tmp_threshold="${DEFAULT_TMP_THRESHOLD}"
  [[ "${parser_threshold}" =~ ^[0-9]+$ ]] || parser_threshold="${DEFAULT_PARSER_THRESHOLD}"

  local -a reasons=()
  if (( tmp_count >= tmp_threshold )); then
    reasons+=("/tmp/*.sh invocations ${tmp_count} >= threshold ${tmp_threshold}")
  fi
  if (( parser_count >= parser_threshold )); then
    reasons+=("parser-fallback pattern hits ${parser_count} >= threshold ${parser_threshold}")
  fi

  (( ${#reasons[@]} == 0 )) && return 0

  # Already raised in conversation?
  local skill_mentions
  skill_mentions="$(jq -s --arg p "${SKILLIFICATION_MENTION_REGEX}" '
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

  [[ "${skill_mentions}" =~ ^[0-9]+$ ]] || skill_mentions=0

  if (( skill_mentions > 0 )); then
    return 0
  fi

  # Throttle: once per session per signal-set. Bucket counts by /3 so a
  # single session does not nag on every Stop event.
  local signal_hash marker_path
  signal_hash="$(printf '%s|%s' "$((tmp_count / 3))" "$((parser_count / 3))" | md5sum | cut -d' ' -f1)"
  marker_path="${TMP_DIR}/claude-skillification-${session_id:-anon}-${signal_hash}"
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
  msg="$(printf 'Skillification reminder: this session shows ad-hoc patterns worth promoting.\nSignals:%s\nIf you noticed any of: a /tmp/*.sh you ran 3+ times, a parser-warning one-liner you retyped 3+ times, a slash-command gap, or a bug in an existing skill -- surface the candidate now as a named follow-up (script / command / skill / issue).\nSee .claude/skills/skillification-candidates/SKILL.md for the four categories and the offer phrasing.\nSet SKILLIFICATION_REMIND_DISABLE=1 to silence.' \
    "${reasons_md}")"

  # Stop event JSON: top-level systemMessage only.
  jq -n --arg m "${msg}" '{systemMessage: $m}'
  return 0
}

main "$@"
