#!/usr/bin/env bash
# checkpoint.sh — /tmp checkpoint protocol helper (ADR-00000002).
#
# Sourced by Tier 2 E2 enforcement hooks (enforce_make_first_upgrade /
# enforce_batch_via_script / enforce_worktree_for_branch). When a hook
# detects a command it wants to gate, it calls:
#
#   write_checkpoint <hook_slug> <cmd> <reason> <canonical> <ack_hint>
#
# which renders a five-section markdown checkpoint to
# $TMPDIR/claude-checkpoint-<hook_slug>-<session_id>-<cmd_hash>.md
# spelling out:
#
#   1. Attempted   — the verbatim command the agent was about to run
#   2. Why gated   — one-paragraph reason from the hook
#   3. Canonical   — the documented entry the agent should use instead
#   4. Ack hint    — explicit `touch <ack-file>` command for the user to
#                    paste back, gated through auto_allow_touch_ack.sh
#   5. Re-run hint — instruction that re-issuing the same command after
#                    ack is the normal way to proceed
#
# is_acked <hook_slug> <cmd> echoes the ack file path and returns 0 if
# the matching `.ack` file exists, 1 otherwise. Hooks use this to
# short-circuit before re-rendering the checkpoint, so the second run
# of the same gated command passes through silently.
#
# Session id source: $CLAUDE_SESSION_ID if set, else "nosession". The
# session id keeps unrelated sessions from sharing acks on the same
# machine; a different session must re-acknowledge the same command.
#
# Cmd hash: first 16 hex chars of sha256(cmd). Different commands
# produce different hashes; identical commands produce identical
# hashes (idempotent ack lookup).

set -uo pipefail

_checkpoint_hash() {
  printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 16)}'
}

_checkpoint_session() {
  printf '%s' "${CLAUDE_SESSION_ID:-nosession}"
}

_checkpoint_tmpdir() {
  printf '%s' "${TMPDIR:-/tmp}"
}

_checkpoint_paths() {
  local hook_slug="$1"
  local cmd="$2"
  local session
  session="$(_checkpoint_session)"
  local hash
  hash="$(_checkpoint_hash "${cmd}")"
  local tmpdir
  tmpdir="$(_checkpoint_tmpdir)"
  local base="${tmpdir}/claude-checkpoint-${hook_slug}-${session}-${hash}"
  printf '%s\n%s\n%s\n' "${base}.md" "${base}.ack" "${base}"
}

# write_checkpoint <hook_slug> <cmd> <reason> <canonical> <ack_hint>
#
# Renders the five-section markdown checkpoint and echoes the absolute
# path to the file. The companion ack path is derived from the same
# slug + session + cmd hash; the printed `touch ...` ack command uses
# the literal $TMPDIR token so the user sees a portable shell command.
write_checkpoint() {
  local hook_slug="$1"
  local cmd="$2"
  local reason="$3"
  local canonical="$4"
  local ack_hint="$5"

  local md_path ack_path
  {
    read -r md_path
    read -r ack_path
  } < <(_checkpoint_paths "${hook_slug}" "${cmd}")

  local ack_basename="${ack_path##*/}"
  local ack_token="\$TMPDIR/${ack_basename}"

  cat > "${md_path}" <<EOF
# Checkpoint: ${hook_slug}

## 1. Attempted

\`\`\`
${cmd}
\`\`\`

## 2. Why gated

${reason}

## 3. Canonical path

${canonical}

## 4. Acknowledge

If you want to proceed with the original command anyway, run:

\`\`\`
touch ${ack_token}
\`\`\`

The companion PreToolUse hook \`auto_allow_touch_ack.sh\` allows this
\`touch\` without an extra prompt.

## 5. Re-run

After ack, re-issue the original command. The hook will look up the
ack by command hash and let it through silently.

${ack_hint}
EOF

  printf '%s\n' "${md_path}"
}

# is_acked <hook_slug> <cmd>
#
# Returns 0 (and prints the ack path) if the matching ack file exists,
# 1 otherwise. Hooks call this at the top of main() to short-circuit
# before re-rendering a checkpoint for a command the user already
# acknowledged.
is_acked() {
  local hook_slug="$1"
  local cmd="$2"

  local md_path ack_path
  {
    read -r md_path
    read -r ack_path
  } < <(_checkpoint_paths "${hook_slug}" "${cmd}")

  if [[ -f "${ack_path}" ]]; then
    printf '%s\n' "${ack_path}"
    return 0
  fi
  return 1
}
