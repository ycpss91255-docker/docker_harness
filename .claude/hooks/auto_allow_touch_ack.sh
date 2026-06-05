#!/usr/bin/env bash
# auto_allow_touch_ack.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Auto-allow `touch <TMPDIR-or-/tmp>/claude-checkpoint-*.ack` invocations
# emitted by the /tmp checkpoint protocol (ADR-00000002). Without this,
# every ack would land in the generic Bash(touch:*) ask flow, defeating
# the one-click ack design that the three Tier 2 E2 enforcement hooks
# (enforce_make_first_upgrade / enforce_batch_via_script /
# enforce_worktree_for_branch) rely on.
#
# Decision matrix:
#   - command not starting with `touch`          → silent
#   - command contains `&&` / `||` / `;` / `|`   → silent (chain too risky)
#   - more than one path arg                     → silent
#   - any path arg has `..` segment              → silent (path traversal)
#   - path arg not matching the ack glob         → silent
#   - matches → emit permissionDecision: allow
#
# The ack glob, evaluated case-sensitively against the resolved path arg:
#   ^(/tmp|\$TMPDIR)/claude-checkpoint-[A-Za-z0-9_-]+\.ack$
#
# The literal token `$TMPDIR` is accepted because the helper module
# .claude/scripts/lib/checkpoint.sh prints the ack hint with `$TMPDIR`
# left unexpanded so users see a path that works in any shell session.

set -uo pipefail

# shellcheck disable=SC2016  # literal $TMPDIR token intentional, see header.
readonly ACK_PREFIX_RE='^(\$TMPDIR|/tmp)/claude-checkpoint-[A-Za-z0-9_-]+\.ack$'

main() {
  local input cmd
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"

  [[ -z "${cmd}" ]] && return 0

  # First token must be exactly `touch`.
  local first_word
  first_word=$(printf '%s' "${cmd}" | awk '{print $1}')
  [[ "${first_word}" != "touch" ]] && return 0

  # Reject chains / pipes — too risky to blanket-allow alongside a touch.
  if printf '%s' "${cmd}" | grep -qE '[|;&]'; then
    return 0
  fi

  # Word-split after `touch`. We've already rejected chains; naive split OK.
  local -a args
  read -ra args <<< "${cmd}"
  unset 'args[0]'

  local saw_dashdash=0 arg
  local -a paths=()
  for arg in "${args[@]:-}"; do
    [[ -z "${arg}" ]] && continue

    if [[ "${arg}" == "--" ]]; then
      saw_dashdash=1
      continue
    fi

    # Pre-`--`, args starting with `-` are flags; skip without recording.
    if (( !saw_dashdash )) && [[ "${arg}" == -* ]]; then
      continue
    fi

    paths+=("${arg}")
  done

  # Require exactly one path arg — the ack file.
  (( ${#paths[@]} == 1 )) || return 0

  local path="${paths[0]}"

  # Reject `..` path-traversal.
  if [[ "${path}" =~ (^|/)\.\.(/|$) ]]; then
    return 0
  fi

  # Final shape check against the ack glob.
  if [[ ! "${path}" =~ ${ACK_PREFIX_RE} ]]; then
    return 0
  fi

  jq -n --arg p "${path}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: ("checkpoint ack " + $p + " — /tmp checkpoint protocol (ADR-00000002)")
    }
  }'

  return 0
}

main "$@"
