#!/usr/bin/env bash
# remind_no_heredoc_redirect.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. When the command writes a file via
# heredoc redirect (`cat <<EOF > /path` style), emit a JSON systemMessage
# nudging Claude to use the Write tool instead. Non-blocking — exit 0.
#
# Why: Claude Code's bash AST parser cannot parse heredoc-to-file
# redirects (`Unhandled node type: file_redirect` warning), so every such
# command falls through to ask, prompting the user. Using the Write tool
# bypasses the parser entirely and is the canonical way for an agent to
# create files.
#
# Trigger: command contains `cat <<...> /path` or `cat <<...>> /path`
# heredoc-to-file redirect. Silent on heredoc piped to commands
# (`cat <<EOF | sh`) and plain redirects without heredoc (`echo > file`).

set -uo pipefail

main() {
  local input cmd msg
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"

  [[ -z "${cmd}" ]] && return 0

  # Match `cat <<[-]['"]TERM['"] >[>] <path>` — heredoc terminator
  # followed by a redirect to file. Anchor `cat` to a command-start
  # position (^ or after ;|&) so descriptions of the pattern inside
  # quoted strings (e.g. a git commit message documenting the rule)
  # do not trigger.
  if ! printf '%s' "${cmd}" | grep -qE '(^|[;&|])[[:space:]]*cat[[:space:]]+<<-?[[:space:]]*[[:graph:]]+[[:space:]]+>>?[[:space:]]+[^|&;]+'; then
    return 0
  fi

  msg="Heredoc-to-file redirect (cat <<EOF > path) hits Claude Code parser warning \"Unhandled node type: file_redirect\" → user prompt. Use the Write tool to create the file directly (no parser warning, no prompt). If you truly must write inline (e.g. generating an inline shell script), wrap it in \`bash -c '...'\` (Bash(bash -c *) is already in the allowlist)."

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
