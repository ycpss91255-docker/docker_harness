#!/usr/bin/env bash
# check_no_emoji.sh — Claude Code PostToolUse hook
#
# Fires on Edit / Write / MultiEdit. Scans the touched file for emoji
# codepoints. On hits, emits a JSON systemMessage. Non-blocking — exit 0.
#
# Project rule (workspace/docker/CLAUDE.md): "不使用 emoji" (no emoji). The detector
# targets emoji-presentation ranges in the BMP supplemental planes
# (1F300+) and regional indicators / dingbats. Common typography (arrows,
# bullets, geometric shapes in 2600-26FF) is intentionally excluded to
# avoid false-positives on warning signs and similar — extend the regex
# only if real misses surface.

set -uo pipefail

main() {
  local input file_path hits msg
  input="$(cat)"
  file_path="$(printf '%s' "${input}" | jq -r '
    .tool_input.file_path
    // .tool_response.filePath
    // empty
  ' 2>/dev/null)"

  [[ -z "${file_path}" || ! -f "${file_path}" ]] && return 0

  case "${file_path}" in
    */.git/*|*/node_modules/*|*/coverage/*|*/.cache/*) return 0 ;;
    # Meta-docs that legitimately quote the rules they enforce
    # (mirrors check_no_ai_attribution.sh skip list).
    */CLAUDE.md|*/.claude/commands/*.md|*/.claude/skills/*/SKILL.md) return 0 ;;
    */.claude/instincts.yaml) return 0 ;;
    */doc/test/TEST.md|*/doc/changelog/CHANGELOG.md) return 0 ;;
    # Hook-test fixtures may legitimately contain emoji bytes for detection tests.
    */.claude/hooks/test/*) return 0 ;;
  esac

  if file --mime "${file_path}" 2>/dev/null | grep -qE 'charset=binary'; then
    return 0
  fi

  hits="$(python3 - "${file_path}" <<'PY' 2>/dev/null
import re
import sys

PATTERN = re.compile(
    "["
    "\U0001F300-\U0001F5FF"   # misc symbols & pictographs
    "\U0001F600-\U0001F64F"   # emoticons
    "\U0001F680-\U0001F6FF"   # transport & map
    "\U0001F700-\U0001F77F"   # alchemical
    "\U0001F780-\U0001F7FF"   # geometric extended
    "\U0001F900-\U0001F9FF"   # supplemental symbols
    "\U0001FA00-\U0001FAFF"   # extended-A
    "\U0001F1E6-\U0001F1FF"   # regional indicators
    "\U00002700-\U000027BF"   # dingbats
    "]"
)

path = sys.argv[1]
hits = []
try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for lineno, line in enumerate(f, 1):
            for m in PATTERN.finditer(line):
                snippet = line.rstrip()[:80]
                hits.append(f"  line {lineno}: {m.group(0)} -> {snippet}")
                if len(hits) >= 5:
                    break
            if len(hits) >= 5:
                break
except OSError:
    pass
print("\n".join(hits))
PY
)"

  if [[ -n "${hits}" ]]; then
    msg="$(printf 'Emoji detected in %s (project rule "不使用 emoji" / no emoji):\n%s' \
      "${file_path}" "${hits}")"
    jq -n --arg m "${msg}" '{
      systemMessage: $m,
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $m
      }
    }'
  fi

  return 0
}

main "$@"
