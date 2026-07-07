#!/usr/bin/env bash
# enforce_worktree_for_branch.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# DENIES `git checkout -b|-B <branch>` invocations that target the main
# checkout. CLAUDE.md "Git 工作流程 > 主 checkout 狀態" (Git workflow >
# main checkout state) rule: the main
# checkout must continuously ff-track origin/main HEAD and never grow a
# feature branch. Non-main work lives in `<workspace>/worktree/<repo>-<N>/`.
# PR #89 hit exactly this failure mode -- local main grew a branch from a
# stale base and required a forced rebase.
#
# Detection: a worktree's `git rev-parse --git-dir` differs from
# `--git-common-dir` (worktree's git-dir lives at
# `<common-dir>/worktrees/<name>`); in the main checkout the two paths
# resolve to the same directory. This is symmetric to how `git worktree`
# itself marks a worktree -- no path string heuristics needed.
#
# Pass-through silent when:
#   - command doesn't match `git checkout -b|-B <branch>`
#   - the target git dir is a worktree (--git-dir != --git-common-dir)
#   - the resolved cwd / -C target is not a git repo
#   - empty command
#
# Out of scope: `git switch -c <branch>` -- possible follow-up if abuse
# surfaces; sibling hook `check_main_fresh_before_worktree.sh` guards the
# inverse failure mode (worktree add from a stale main).
#
# Lift: same `/tmp` checkpoint protocol (ADR-00000002 / #117).
#
# Refs: issue #122 (this hook), #117 (checkpoint helper), #116 Tier 2,
#       PR #89 (precedent incident).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HOOK_DIR}/../scripts/lib/checkpoint.sh"

readonly HOOK_SLUG="enforce-worktree-for-branch"
readonly REASON='Branch creation in the main checkout violates the worktree rule -- the main checkout must continuously ff-track origin/main HEAD. PR #89 precedent: local main grew a branch from a stale base and required a forced rebase.'

main() {
  local input cmd cwd
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  cwd="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
  [[ -z "${cwd}" ]] && cwd="${PWD}"

  [[ -z "${cmd}" ]] && return 0

  # Match `git [-C <path>] checkout (-b|-B) <branch>`.
  local branch=""
  if [[ "${cmd}" =~ git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?checkout[[:space:]]+(-b|-B)[[:space:]]+([^[:space:]]+) ]]; then
    branch="${BASH_REMATCH[3]}"
  else
    return 0
  fi
  [[ -z "${branch}" ]] && return 0

  # Resolve target work dir: -C arg takes precedence over cwd.
  local work_dir=""
  if [[ "${cmd}" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
    work_dir="${BASH_REMATCH[1]}"
  fi
  [[ -z "${work_dir}" ]] && work_dir="${cwd}"
  [[ "${work_dir}" != /* ]] && work_dir="${cwd}/${work_dir}"

  # Resolve git-dir + common-dir; non-repo -> silent.
  local git_dir common_dir
  git_dir="$(git -C "${work_dir}" rev-parse --git-dir 2>/dev/null)"
  [[ -z "${git_dir}" ]] && return 0
  common_dir="$(git -C "${work_dir}" rev-parse --git-common-dir 2>/dev/null)"
  [[ -z "${common_dir}" ]] && return 0

  # Normalize to absolute, comparable paths.
  local abs_git_dir abs_common_dir
  abs_git_dir="$(cd "${work_dir}" 2>/dev/null && cd "${git_dir}" 2>/dev/null && pwd)"
  abs_common_dir="$(cd "${work_dir}" 2>/dev/null && cd "${common_dir}" 2>/dev/null && pwd)"
  [[ -z "${abs_git_dir}" || -z "${abs_common_dir}" ]] && return 0

  # In a worktree, abs_git_dir != abs_common_dir -- fall through.
  if [[ "${abs_git_dir}" != "${abs_common_dir}" ]]; then
    return 0
  fi

  # Main checkout: gate.
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

  local repo_root canonical
  repo_root="$(git -C "${work_dir}" rev-parse --show-toplevel 2>/dev/null)"
  [[ -z "${repo_root}" ]] && repo_root="${work_dir}"
  local repo_name
  repo_name="$(basename "${repo_root}")"
  canonical="git worktree add ${repo_root%/*}/worktree/${repo_name}-<N> -b ${branch} main"

  local md_path
  md_path="$(write_checkpoint \
    "${HOOK_SLUG}" \
    "${cmd}" \
    "${REASON}" \
    "${canonical}" \
    "See CLAUDE.md > Git 工作流程 (Git workflow) > git worktree usage for the full rule.")"

  local deny_msg
  deny_msg="worktree-for-branch gate (PR #89 precedent): \`git checkout -${BASH_REMATCH[2]:-b} ${branch}\` in the main checkout is denied.
Canonical:
  ${canonical}
Why: ${REASON}
Checkpoint written to:
  ${md_path}
If you really want to branch from the main checkout, touch the matching
ack file (see section 4 of the checkpoint), then re-issue the same command.
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

main "$@"
