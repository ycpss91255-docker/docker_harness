#!/usr/bin/env bash
# auto_allow_touch_ack.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Auto-allow `touch <TMPDIR-or-/tmp>/claude-checkpoint-*.ack` invocations
# emitted by the /tmp checkpoint protocol (ADR-00000002). Without this,
# every ack would land in the generic Bash(touch:*) ask flow, defeating
# the one-click ack design that the three Tier 2 E2 enforcement hooks
# (enforce_wrapper_first_upgrade / enforce_batch_via_script /
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
  local input cmd agent_marker
  input="$(cat)"

  # An ack records a HUMAN's intent to lift a Tier 2 E2 gate, so an agent
  # writing one is never legitimate -- it lifts the gate instead of passing
  # it. Hooks do fire for subagent tool calls, and a subagent payload carries
  # `agent_id` / `agent_type` that a main-session payload does not, so those
  # are DENIED outright.
  #
  # Denying rather than staying silent is the #267 defect this corrects
  # (refs #274). Silence does not hand the decision back to a human: with no
  # hook decision the permission layer judges a bare `touch` of a /tmp path
  # benign and approves it unasked, so the ack still got written -- confirmed
  # at runtime, where a Workflow agent created the file uninterrupted. Note
  # `session_id` cannot serve as the discriminator here: it is identical for
  # parent and child, as is CLAUDE_CODE_CHILD_SESSION.
  local agent_marker
  agent_marker="$(printf '%s' "${input}" \
    | jq -r '(.agent_id // "") + (.agent_type // "")' 2>/dev/null)"
  if [[ -n "${agent_marker}" ]]; then
    jq -nc '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("a checkpoint ack records a human decision to lift a Tier 2 E2 gate, so it cannot come from an agent. Report what you need lifted and why, and let the interactive session ack it (ADR-00000002, ADR-00000014)")
      }
    }'
    return 0
  fi

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
