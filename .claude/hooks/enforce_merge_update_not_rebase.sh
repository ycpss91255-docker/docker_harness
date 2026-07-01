#!/usr/bin/env bash
# enforce_merge_update_not_rebase.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# Policy (refs issue #221): `git rebase` is disallowed org-wide. A stale PR
# (mergeStateStatus BEHIND / CONFLICTING) is refreshed by merging the base
# branch into the PR branch and pushing NORMALLY -- never by rebasing +
# force-pushing:
#
#   git fetch origin && git merge origin/main   # update the branch
#   git push                                     # normal push, NO --force
#
# Two deny surfaces, both liftable via the /tmp checkpoint + touch-ACK
# protocol (ADR-00000002 / #117) so an explicit ack overrides:
#
#   1. `git rebase ...` in ANY position of the command (including
#      `git -C <dir> rebase`) is DENIED and steered to `git merge
#      origin/main` + a normal push. `git pull --rebase` counts as a
#      rebase and is DENIED too (steered to plain `git pull` / merge).
#      EXEMPT the in-progress recovery flags `--abort` / `--continue` /
#      `--skip` -- those let an operator finish or escape a rebase that
#      is already underway, so they pass through SILENTLY.
#
#   2. `git push --force` / `-f` / `--force-with-lease` is DENIED ONLY
#      WHEN the current branch has an OPEN PR (rewriting a PR branch's
#      history breaks review threads + CI history). Branch is resolved
#      from an explicit `origin <branch>` in the push command, else from
#      `git -C <cwd> branch --show-current`; the open-PR check is a
#      `gh pr list --head <branch> --state open` query. Force-push on a
#      branch with NO open PR (or when gh errors / is unavailable) stays
#      SILENT -- fail-open; the existing settings `ask` bucket already
#      prompts on force-push, so a no-PR force-push remains allowed.
#
# Everything else (non-git, non-rebase, non-force-push git) -> silent
# exit 0. This hook is text-only (no repo mutation) and ALWAYS fails open
# (exit 0) on its own internal errors.
#
# Companion skill: .agents/skills/update-stale-pr/SKILL.md
# Companion script: .claude/scripts/update-stale-pr.sh
#
# Refs: issue #221.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HOOK_DIR}/../scripts/lib/checkpoint.sh"

readonly HOOK_SLUG="enforce-merge-update-not-rebase"

# is_git_rebase <cmd> -- true if the command runs `git rebase` in any
# position (bare or via `git -C <dir> rebase`). `git pull --rebase` is
# handled separately (its `rebase` is a flag, not the subcommand token).
is_git_rebase() {
  printf '%s' "$1" | grep -qE \
    'git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?rebase([[:space:]]|$)'
}

# is_pull_rebase <cmd> -- true if the command is `git pull` carrying a
# `--rebase` flag.
is_pull_rebase() {
  printf '%s' "$1" | grep -qE \
    'git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?pull([[:space:]]|$)' \
    && printf '%s' "$1" | grep -qE '(^|[[:space:]])--rebase([[:space:]=]|$)'
}

# has_recovery_flag <cmd> -- true if the command carries an in-progress
# rebase recovery flag (--abort / --continue / --skip). These are exempt.
has_recovery_flag() {
  printf '%s' "$1" | grep -qE '(^|[[:space:]])--(abort|continue|skip)([[:space:]]|$)'
}

# is_force_push <cmd> -- true if the command is a `git push` carrying a
# force flag (--force / -f / --force-with-lease).
is_force_push() {
  printf '%s' "$1" | grep -qE \
    'git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?push' \
    && printf '%s' "$1" | grep -qE \
    '(^|[[:space:]])(--force-with-lease|--force|-f)([[:space:]]|=|$)'
}

# push_work_dir <cmd> <cwd> -- echo the git working directory for the
# push: an explicit `git -C <dir>` wins, else <cwd>.
push_work_dir() {
  local cmd="$1" cwd="$2"
  if [[ "${cmd}" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '%s' "${cwd}"
}

# resolve_branch <cmd> <dir> -- echo the branch the push targets. An
# explicit `origin <ref>` in the command wins (local side of a
# `local:remote` refspec); else `git -C <dir> branch --show-current`.
resolve_branch() {
  local cmd="$1" dir="$2" ref=""
  if [[ "${cmd}" =~ [[:space:]]origin[[:space:]]+([^[:space:]]+) ]]; then
    ref="${BASH_REMATCH[1]}"
    ref="${ref#+}"        # strip a leading '+' (force refspec)
    ref="${ref%%:*}"      # keep the local side of local:remote
    printf '%s' "${ref}"
    return 0
  fi
  git -C "${dir}" branch --show-current 2>/dev/null
}

# branch_has_open_pr <branch> <dir> -- return 0 if <branch> has >=1 OPEN
# PR. Fails open (returns 1) when gh errors / is unavailable / the count
# cannot be parsed, so the caller stays silent. gh resolves the repo from
# <dir>'s origin remote.
branch_has_open_pr() {
  local branch="$1" dir="$2" prs count
  [[ -n "${branch}" ]] || return 1
  prs="$(cd "${dir}" 2>/dev/null \
    && gh pr list --head "${branch}" --state open --json number 2>/dev/null)" \
    || return 1
  count="$(printf '%s' "${prs}" | jq 'length' 2>/dev/null)" || return 1
  [[ "${count}" =~ ^[0-9]+$ ]] || return 1
  (( count >= 1 ))
}

# gate_deny <cmd> <reason> <canonical> <header> -- emit the deny JSON via
# the checkpoint + touch-ACK protocol, or an allow JSON if the same
# command was already acked.
gate_deny() {
  local cmd="$1" reason="$2" canonical="$3" header="$4"

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

  local md_path
  md_path="$(write_checkpoint \
    "${HOOK_SLUG}" \
    "${cmd}" \
    "${reason}" \
    "${canonical}" \
    "See .agents/skills/update-stale-pr/SKILL.md for the merge-update flow.")"

  local deny_msg
  deny_msg="${header}
${canonical}
Why: ${reason}
Checkpoint written to:
  ${md_path}
If you really want to run the original command, touch the matching ack
file (see section 4 of the checkpoint), then re-issue the same command.
The companion auto_allow_touch_ack.sh hook allows the ack touch."

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

main() {
  local input cmd cwd
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  cwd="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
  [[ -z "${cwd}" ]] && cwd="${PWD}"
  [[ -z "${cmd}" ]] && return 0

  # Surface 1: git rebase / git pull --rebase.
  if is_git_rebase "${cmd}" || is_pull_rebase "${cmd}"; then
    # Recovery flags let an operator finish / escape an in-progress
    # rebase -- stay silent so they are not blocked.
    if has_recovery_flag "${cmd}"; then
      return 0
    fi
    gate_deny "${cmd}" \
      'git rebase is disallowed org-wide (refs #221). A stale PR is refreshed by merging the base branch in, not by rewriting history.' \
      'Update the branch with a merge instead: git fetch origin && git merge origin/main, then a normal git push (no force). One-shot: .claude/scripts/update-stale-pr.sh <pr>.' \
      'merge-update gate (issue #221): git rebase / git pull --rebase is denied.'
    return 0
  fi

  # Surface 2: git push --force / -f / --force-with-lease on a branch
  # that has an open PR.
  if is_force_push "${cmd}"; then
    local dir branch
    dir="$(push_work_dir "${cmd}" "${cwd}")"
    branch="$(resolve_branch "${cmd}" "${dir}")"
    if branch_has_open_pr "${branch}" "${dir}"; then
      gate_deny "${cmd}" \
        "Branch '${branch}' has an open PR; force-pushing rewrites its history and breaks the review threads + CI record (refs #221)." \
        'Refresh the PR branch with a merge instead: git fetch origin && git merge origin/main, then a normal git push (no force). One-shot: .claude/scripts/update-stale-pr.sh <pr>.' \
        'merge-update gate (issue #221): force-push on a branch with an open PR is denied.'
      return 0
    fi
    # No open PR (or gh unavailable) -> fail open, stay silent.
    return 0
  fi

  return 0
}

main "$@"
