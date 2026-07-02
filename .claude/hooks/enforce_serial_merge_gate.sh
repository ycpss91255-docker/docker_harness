#!/usr/bin/env bash
# enforce_serial_merge_gate.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# DENIES the 2nd+ same-repo `gh pr merge ... --auto` arm of a batch and
# routes the operator to serial-merge.sh. Under strict branch protection
# (base must be up to date before merge), arming auto-merge on N same-repo
# PRs at once is O(N^2) in CI runs: each merge advances base, marking every
# other armed PR BEHIND and forcing an update-branch re-run for all of them.
# serial-merge.sh lands them one at a time -> O(N).
#
# Detection (all must hold):
#   1. command arms auto-merge:  `gh ... pr ... merge ... --auto ...`
#   2. the target repo already has >= 1 open PR armed for auto-merge, as
#      reported by `gh pr list --repo <repo> --state open --json
#      number,autoMergeRequest` (the PR being armed is excluded, so an
#      idempotent re-arm of an already-armed PR does NOT trip the gate).
#
# On block the deny reason is data-rich (issue #236): the target repo, the
# count + list of already-armed PRs, and a ready-to-paste
# `.claude/scripts/serial-merge.sh <repo> <armed...> <this-pr>` command.
#
# Pass-through silent when:
#   - command is not a `gh pr merge` arm (no `merge` verb / no `--auto`)
#   - 0 PRs already armed (single-PR arm -> zero added latency)
#   - the gh query fails / returns nothing (fail-open: a gh outage must not
#     block a legitimate single arm)
#   - SERIAL_MERGE=1 bypass, as an env var or an inline `SERIAL_MERGE=1 ...`
#     command prefix (serial-merge.sh sets this so its own per-PR arm --
#     which can coexist with a stale-armed failed PR -- never self-blocks)
#   - empty command
#
# Lift mechanism: the /tmp checkpoint protocol (ADR-00000002 / #117). On
# deny, write_checkpoint renders a five-section markdown and quotes the
# matching `touch <ack>` command; a second attempt of the same command
# (sha256(cmd)-16hex hash) hits is_acked and is allowed through. The
# companion auto_allow_touch_ack.sh hook allows the ack touch.
#
# Refs: issue #236 (this hook), #235 (serial-merge.sh), #117 (checkpoint
#       helper), ADR-00000002.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HOOK_DIR}/../scripts/lib/checkpoint.sh"

readonly HOOK_SLUG="enforce-serial-merge-gate"
readonly DEFAULT_OWNER='ycpss91255-docker'
readonly REASON='Arming auto-merge on multiple same-repo PRs at once is O(N^2) in CI runs under strict branch protection (each merge marks the others BEHIND, forcing an update-branch re-run). serial-merge.sh lands them one at a time -> O(N).'

main() {
  local input cmd
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [[ -z "${cmd}" ]] && return 0

  # SERIAL_MERGE=1 explicit bypass (env var OR inline command prefix).
  if [[ "${SERIAL_MERGE:-}" == "1" ]] \
     || [[ "${cmd}" =~ (^|[[:space:]])SERIAL_MERGE=1([[:space:]]) ]]; then
    return 0
  fi

  # Find the command SEGMENT that arms auto-merge. Split on && || | ; so a
  # `gh pr merge --auto` inside a quoted arg of another command (e.g. a
  # commit message) does not false-trigger (cf #219 close_segment). A
  # segment qualifies when, after any VAR=val env prefix, it begins with
  # `gh pr merge` and carries --auto.
  local segments seg s merge_seg=""
  segments="$(printf '%s' "${cmd}" | sed 's/&&/\n/g; s/||/\n/g; s/|/\n/g; s/;/\n/g')"
  while IFS= read -r seg; do
    s="${seg#"${seg%%[![:space:]]*}"}"
    while [[ "${s}" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+ ]]; do
      s="${s#"${BASH_REMATCH[0]}"}"
    done
    if [[ "${s}" =~ ^gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$) ]] \
       && [[ "${s}" =~ (^|[[:space:]])--auto([[:space:]]|$) ]]; then
      merge_seg="${s}"
      break
    fi
  done <<< "${segments}"
  [[ -z "${merge_seg}" ]] && return 0

  # Extract the target repo from --repo <val> / -R <val> / --repo=<val> in
  # the merge segment; else resolve the cwd repo so the remediation command
  # is well-formed instead of carrying an empty repo slot.
  local repo=""
  if [[ "${merge_seg}" =~ (--repo|-R)[[:space:]=]+([^[:space:]]+) ]]; then
    repo="${BASH_REMATCH[2]}"
  fi
  if [[ -z "${repo}" ]]; then
    repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || repo=""
  fi
  # Short repo name -> default-owner expansion (mirrors serial-merge.sh).
  if [[ -n "${repo}" && "${repo}" != */* ]]; then
    repo="${DEFAULT_OWNER}/${repo}"
  fi
  # Cannot resolve a repo -> fail open (a malformed remediation would mislead).
  [[ -z "${repo}" ]] && return 0

  # Extract the PR being armed: first bare-integer token after `merge`.
  local this_pr=""
  local tail="${merge_seg#*merge}"
  local tok
  for tok in ${tail}; do
    if [[ "${tok}" =~ ^[0-9]+$ ]]; then
      this_pr="${tok}"
      break
    fi
  done

  # Query the repo's open PRs already armed for auto-merge. Fail-open: any
  # error / empty result is treated as "0 armed" so a gh outage never blocks
  # a legitimate single arm.
  local list_json="" armed=""
  list_json="$(gh pr list --repo "${repo}" --state open \
    --json number,autoMergeRequest 2>/dev/null)" || list_json=""
  [[ -z "${list_json}" ]] && return 0

  # Armed PR numbers (autoMergeRequest != null), excluding the one being
  # armed (idempotent re-arm must not self-trip).
  armed="$(printf '%s' "${list_json}" | jq -r --arg self "${this_pr}" '
    [ .[] | select(.autoMergeRequest != null) | .number | tostring ]
    | map(select(. != $self)) | join(" ")' 2>/dev/null)" || armed=""

  # No already-armed PR -> allow (single arm, zero added latency).
  [[ -z "${armed}" ]] && return 0

  local -a armed_arr
  read -ra armed_arr <<< "${armed}"
  local count="${#armed_arr[@]}"

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

  # Render the armed list (`#773, #774`) and the ready-to-paste command.
  local armed_hashed="" n
  for n in "${armed_arr[@]}"; do
    armed_hashed+="${armed_hashed:+, }#${n}"
  done
  local pr_label="${this_pr:-<pr>}"
  local serial_cmd=".claude/scripts/serial-merge.sh ${repo} ${armed} ${pr_label}"

  local md_path
  md_path="$(write_checkpoint \
    "${HOOK_SLUG}" \
    "${cmd}" \
    "${REASON}" \
    "${serial_cmd}" \
    "Set SERIAL_MERGE=1 to bypass this gate for a single arm (serial-merge.sh does this itself).")"

  local deny_msg
  deny_msg="serial-merge gate (issue #236): ${repo} already has ${count} auto-merge-armed PR(s): ${armed_hashed}
Arming #${pr_label} starts a same-repo batch -> under strict branch protection this causes O(N^2) redundant CI re-runs.
Run instead:
  ${serial_cmd}
Why: ${REASON}
Checkpoint written to:
  ${md_path}
If you really want to arm this PR individually, touch the matching ack file
(see section 4 of the checkpoint) then re-issue the same command, or set
SERIAL_MERGE=1. The companion auto_allow_touch_ack.sh hook allows the ack touch."

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
