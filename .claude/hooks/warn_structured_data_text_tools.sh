#!/usr/bin/env bash
# warn_structured_data_text_tools.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. When the command parses a JSON / JSONL
# file with line-oriented text tools (`awk` / `sed`), emit a JSON
# systemMessage nudging Claude to use `jq` (or the Read / Grep tools)
# instead. Non-blocking — exit 0, never deny.
#
# Why: parsing multi-line JSON / JSONL with `awk` / `sed` is fragile.
# A JSONL record can span lines and embed `}`, ```` ``` ````, heredoc
# bodies, etc.; a line-oriented matcher counts those as data rows and
# produces silently-wrong results (observed 2026-06-08 while tallying
# transcript tool-call frequencies — the awk pass miscounted and the
# whole analysis had to be redone with jq). `jq` parses the structure
# correctly; the Grep tool is the right way to search code.
#
# Trigger (all three must hold, to keep false positives low):
#   1. `awk` or `sed` appears at a command-start position (^ or after
#      ; & |) — so prose describing the rule inside a quoted string
#      (e.g. a commit message) does not trigger.
#   2. the command references a `.json` / `.jsonl` path.
#   3. `jq` is ABSENT — `jq ... file.json | awk '{print $1}'` is the
#      correct pattern (jq extracts, awk formats clean columns) and
#      must stay silent.

set -uo pipefail

main() {
  local input cmd msg
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"

  [[ -z "${cmd}" ]] && return 0

  # 3. jq present anywhere → assume correct usage, stay silent.
  if printf '%s' "${cmd}" | grep -qE '(^|[[:space:]/;&|])jq([[:space:]]|$)'; then
    return 0
  fi

  # 2. must reference a .json / .jsonl path.
  if ! printf '%s' "${cmd}" | grep -qE '\.jsonl?([[:space:]"'\''/]|$)'; then
    return 0
  fi

  # 1. awk / sed at a command-start position (^ or after ; & |).
  if ! printf '%s' "${cmd}" | grep -qE '(^|[;&|])[[:space:]]*(awk|sed)[[:space:]]'; then
    return 0
  fi

  msg="awk/sed parsing JSON/JSONL is fragile — a record can span lines and embed }, backticks, heredoc bodies, so a line-oriented matcher miscounts and silently produces wrong results. 結構化資料(JSON/JSONL)請改用 \`jq\`(取值 / 計數:\`jq -r '...' | sort | uniq -c\`);搜尋程式碼走 Grep 工具。awk/sed/cat pipeline 只保留給乾淨的表格 / 欄位資料(如 \`jq ... | awk '{print \$1}'\` 在 jq 抽完後格式化欄位)。"

  jq -n --arg m "${msg}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $m
    }
  }'

  return 0
}

main "$@"
