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
#   1. A `git rebase` command (the rebase SUBCOMMAND, incl. `git -C <dir>`
#      or `git -c k=v ... rebase`) is DENIED and steered to `git merge
#      origin/main` + a normal push. `git pull --rebase` counts as a
#      rebase and is DENIED too. EXEMPT the in-progress recovery flags
#      `--abort` / `--continue` / `--skip`.
#
#   2. A `git push` carrying a force flag (`--force` / `-f` /
#      `--force-with-lease`) OR a `+refspec` is DENIED ONLY WHEN the
#      current branch has an OPEN PR. Branch is resolved from an explicit
#      `origin <branch>` in that push segment (HEAD/@ -> current branch),
#      else `git -C <cwd> branch --show-current`; the open-PR check is a
#      `gh pr list --head <branch> --state open` query. Force-push on a
#      branch with NO open PR (or when gh errors / is unavailable) stays
#      SILENT (fail-open; the settings `ask` bucket still prompts).
#
# Detection is SEGMENT-scoped: the command is split on `&&` / `||` / `|` /
# `;` and each segment's git subcommand is parsed (skipping env prefixes +
# git global options), so a force flag belonging to a chained non-git
# command (`git push origin main && docker build -f ...`) or the word
# "rebase" inside a commit message (`git commit -m "... rebase ..."`) does
# not false-trigger (refs #219's close_segment for the same class of bug).
#
# Everything else -> silent exit 0. Text-only; ALWAYS fails open (exit 0)
# on its own internal errors.
#
# Companion skill: .agents/skills/update-stale-pr/SKILL.md
# Companion script: .claude/scripts/update-stale-pr.sh
# Refs: issue #221.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HOOK_DIR}/../scripts/lib/checkpoint.sh"

readonly HOOK_SLUG="enforce-merge-update-not-rebase"

# git_subcommand <segment> -- echo the git subcommand of a segment, or
# nothing if the segment is not a `git` command. Skips a leading VAR=val
# env prefix and git global options (value-taking -C/-c/--git-dir/
# --work-tree/--namespace/--exec-path; boolean --no-pager/-p/... and any
# other leading-dash global).
git_subcommand() {
  local -a words
  read -r -a words <<< "$1"
  local i=0 n=${#words[@]}
  while (( i < n )) && [[ "${words[i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    i=$((i + 1))
  done
  [[ "${i}" -lt "${n}" && "${words[i]}" == "git" ]] || return 0
  i=$((i + 1))
  while (( i < n )); do
    case "${words[i]}" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix)
        i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  (( i < n )) && printf '%s' "${words[i]}"
}

# seg_has <segment> <ERE> -- true if a whitespace-delimited token of the
# segment matches the ERE (token-anchored, avoids substring hits).
seg_has() {
  local seg="$1" re="$2" w
  local -a words
  read -r -a words <<< "${seg}"
  for w in "${words[@]}"; do
    [[ "${w}" =~ ${re} ]] && return 0
  done
  return 1
}

# push_dir <segment> <cwd> -- git working dir for a push: explicit
# `git -C <dir>` wins, else <cwd>.
push_dir() {
  local -a words
  read -r -a words <<< "$1"
  local i
  for (( i = 0; i < ${#words[@]} - 1; i++ )); do
    [[ "${words[i]}" == "-C" ]] && { printf '%s' "${words[i+1]}"; return 0; }
  done
  printf '%s' "$2"
}

# resolve_branch <segment> <dir> -- branch the push targets. Explicit
# `origin <ref>` wins (local side of local:remote, leading '+' stripped);
# HEAD/@ and the no-explicit-ref case fall back to the current branch.
resolve_branch() {
  local seg="$1" dir="$2" ref=""
  if [[ "${seg}" =~ [[:space:]]origin[[:space:]]+([^[:space:]]+) ]]; then
    ref="${BASH_REMATCH[1]}"
    ref="${ref#+}"
    ref="${ref%%:*}"
  fi
  if [[ -z "${ref}" || "${ref}" == "HEAD" || "${ref}" == "@" ]]; then
    git -C "${dir}" branch --show-current 2>/dev/null
    return 0
  fi
  printf '%s' "${ref}"
}

# branch_has_open_pr <branch> <dir> -- 0 if <branch> has >=1 OPEN PR.
# Fails open (1) on any gh / parse error.
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
    "${HOOK_SLUG}" "${cmd}" "${reason}" "${canonical}" \
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

  # Split into segments on && || | ; and evaluate each independently.
  local segments sub
  segments="$(printf '%s' "${cmd}" | sed 's/&&/\n/g; s/||/\n/g; s/|/\n/g; s/;/\n/g')"

  while IFS= read -r seg; do
    [[ -z "${seg//[[:space:]]/}" ]] && continue
    sub="$(git_subcommand "${seg}")"

    # Surface 1: git rebase (subcommand) or git pull --rebase.
    if [[ "${sub}" == "rebase" ]] \
       || { [[ "${sub}" == "pull" ]] && seg_has "${seg}" '^--rebase(=.*)?$'; }; then
      seg_has "${seg}" '^--(abort|continue|skip)$' && return 0
      gate_deny "${cmd}" \
        'git rebase is disallowed org-wide (refs #221). A stale PR is refreshed by merging the base branch in, not by rewriting history.' \
        'Update the branch with a merge instead: git fetch origin && git merge origin/main, then a normal git push (no force). One-shot: .claude/scripts/update-stale-pr.sh <pr>.' \
        'merge-update gate (issue #221): git rebase / git pull --rebase is denied.'
      return 0
    fi

    # Surface 2: git push with a force flag or a +refspec, on an open-PR branch.
    if [[ "${sub}" == "push" ]] \
       && { seg_has "${seg}" '^(--force-with-lease|--force|-f)(=.*)?$' \
            || seg_has "${seg}" '^\+'; }; then
      local dir branch
      dir="$(push_dir "${seg}" "${cwd}")"
      branch="$(resolve_branch "${seg}" "${dir}")"
      if branch_has_open_pr "${branch}" "${dir}"; then
        gate_deny "${cmd}" \
          "Branch '${branch}' has an open PR; force-pushing rewrites its history and breaks the review threads + CI record (refs #221)." \
          'Refresh the PR branch with a merge instead: git fetch origin && git merge origin/main, then a normal git push (no force). One-shot: .claude/scripts/update-stale-pr.sh <pr>.' \
          'merge-update gate (issue #221): force-push on a branch with an open PR is denied.'
        return 0
      fi
      return 0
    fi
  done <<< "${segments}"

  return 0
}

main "$@"
