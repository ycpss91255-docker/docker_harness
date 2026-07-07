#!/usr/bin/env bash
# remind_parallel_when_bulk.sh -- Claude Code UserPromptSubmit hook.
#
# Fires when the user submits a prompt. Scans the prompt text for
# bulk-work indicators. If matched AND the prompt does not already
# mention parallel-Agent dispatch, emits a non-blocking systemMessage
# nudge pointing at the parallel-agents skill.
#
# Non-blocking. Cannot spawn Agents itself (hook output schema does
# not support that). Throttled once per session per signal-set via a
# TMPDIR marker, matching the Stop-hook reminder family.
#
# Why: CLAUDE.md "## 主動優化建議 > 工作量大時使用平行 Agent"
# (Proactive optimisation > use parallel Agents for large workloads) requires the
# agent to dispatch parallel Agents (up to 3) when processing 4+
# independent repos / files / PRs. The rule fires inconsistently
# today because there is no enforcement layer. Refs issue
# ycpss91255-docker/docker_harness#126.
#
# Detection patterns (POSIX ERE; matched against the prompt text):
#   A. <N> <plural-noun> where N >= threshold, plural noun in the bulk
#      list (repos / PRs / issues / files / workflows / tests / hooks /
#      directories / branches).
#   B. (all|every|每個|所有|全部) + plural noun from the same list.
#   C. <name>[, <name>]{threshold-1,} -- explicit list with >= threshold
#      comma-separated tokens that look repo-shaped
#      ([a-zA-Z][a-zA-Z0-9_-]*). [stretch goal; pattern C below covers
#      the comma-separated form with low false-positive risk.]
#
# Suppression: prompt already mentions parallel-Agent dispatch (regex
# below). Then stay silent.
#
# Configuration via env vars:
#   PARALLEL_REMIND_THRESHOLD  (default 4)
#   PARALLEL_REMIND_DISABLE    (set to 1 to disable)

set -uo pipefail

readonly DEFAULT_THRESHOLD=4
readonly TMP_DIR="${TMPDIR:-/tmp}"

# Bulk-noun list. Plural noun forms only. Tested against the prompt
# text after lowercasing.
readonly BULK_NOUNS='repos?|prs?|pull requests?|issues?|files?|workflows?|tests?|hooks?|branch|branches|director(y|ies)|repositor(y|ies)'

# Already-mentioned-parallel suppression regex (case-insensitive).
# Matches both English and CJK variants.
readonly PARALLEL_MENTION_REGEX='parallel|concurrent|in parallel|subagent|sub-agent|平行|並行|spawn.*agents?|3 agents|dispatch.*agents?'

main() {
  local input prompt session_id
  input="$(cat)"

  if [[ "${PARALLEL_REMIND_DISABLE:-0}" == "1" ]]; then
    return 0
  fi

  prompt="$(printf '%s' "${input}" | jq -r '.prompt // empty' 2>/dev/null)"
  session_id="$(printf '%s' "${input}" | jq -r '.session_id // empty' 2>/dev/null)"

  [[ -z "${prompt}" ]] && return 0

  local threshold="${PARALLEL_REMIND_THRESHOLD:-${DEFAULT_THRESHOLD}}"
  [[ "${threshold}" =~ ^[0-9]+$ ]] || threshold="${DEFAULT_THRESHOLD}"

  local prompt_lower
  prompt_lower="$(printf '%s' "${prompt}" | tr '[:upper:]' '[:lower:]')"

  # Suppression: already prompting for parallel.
  if [[ "${prompt_lower}" =~ ${PARALLEL_MENTION_REGEX} ]]; then
    return 0
  fi

  local matched_signal=""

  # Pattern A: <N> <bulk-noun>.
  local pattern_a
  pattern_a="([0-9]+)[[:space:]]+(${BULK_NOUNS})"
  if [[ "${prompt_lower}" =~ ${pattern_a} ]]; then
    local n="${BASH_REMATCH[1]}"
    local noun="${BASH_REMATCH[2]}"
    if [[ "${n}" =~ ^[0-9]+$ ]] && (( n >= threshold )); then
      matched_signal="numeric N=${n} >= ${threshold} (${noun})"
    fi
  fi

  # Pattern B: all / every + bulk-noun. Always fires (N implicit).
  if [[ -z "${matched_signal}" ]]; then
    local pattern_b
    pattern_b="(all|every|each)[[:space:]]+(of[[:space:]]+(the[[:space:]]+)?)?(${BULK_NOUNS})"
    if [[ "${prompt_lower}" =~ ${pattern_b} ]]; then
      matched_signal="quantifier '${BASH_REMATCH[1]}' + '${BASH_REMATCH[4]}'"
    fi
  fi

  # Pattern B-CJK: 全部 / 所有 / 每個 + Chinese bulk noun keyword.
  if [[ -z "${matched_signal}" ]]; then
    if [[ "${prompt}" =~ (全部|所有|每個|每一個)(.{0,4})(repo|pr|issue|file|workflow|test|hook|directory|branch) ]]; then
      matched_signal="quantifier '${BASH_REMATCH[1]}' (CJK)"
    fi
  fi

  # Pattern C: explicit comma-separated list of >= threshold
  # repo-shaped tokens. Uses count of commas in the longest matching
  # run; conservative (single-line, no nested punctuation).
  if [[ -z "${matched_signal}" ]]; then
    # Capture sequences like `name1, name2, name3, name4`. Each token:
    # [A-Za-z][A-Za-z0-9_-]*  with `-` and `_` allowed.
    local comma_count
    comma_count="$(printf '%s' "${prompt}" | grep -oE '[A-Za-z][A-Za-z0-9_-]+(, [A-Za-z][A-Za-z0-9_-]+){3,}' | head -1 | tr -cd ',' | wc -c)"
    [[ "${comma_count}" =~ ^[0-9]+$ ]] || comma_count=0
    if (( comma_count >= threshold - 1 )); then
      matched_signal="comma-list with $((comma_count + 1)) tokens"
    fi
  fi

  [[ -z "${matched_signal}" ]] && return 0

  # Throttle: once per session per signal hash.
  local signal_hash marker_path
  signal_hash="$(printf '%s' "${matched_signal}" | md5sum | cut -d' ' -f1)"
  marker_path="${TMP_DIR}/claude-parallel-remind-${session_id:-anon}-${signal_hash}"
  if [[ -f "${marker_path}" ]]; then
    return 0
  fi
  : > "${marker_path}" 2>/dev/null || true

  local msg
  msg="$(printf 'Parallel-Agent reminder: bulk workload detected (%s).\nFor 4+ independent items, dispatch up to 3 parallel Agent tool calls in a single response instead of iterating inline.\nSee .claude/skills/parallel-agents/SKILL.md for the partitioning rubric and the per-Agent prompt shape.\nSet PARALLEL_REMIND_DISABLE=1 to silence; tune PARALLEL_REMIND_THRESHOLD (default 4) to change the bulk floor.' \
    "${matched_signal}")"

  # UserPromptSubmit accepts top-level systemMessage. The agent sees
  # the reminder before composing its response.
  jq -n --arg m "${msg}" '{systemMessage: $m}'
  return 0
}

main "$@"
