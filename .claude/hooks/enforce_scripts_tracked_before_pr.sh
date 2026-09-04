#!/usr/bin/env bash
# enforce_scripts_tracked_before_pr.sh -- Claude Code PreToolUse hook
# (matcher: Bash, refs #282).
#
# Blocks the PR-open commands (`gh pr create` / `gh pr ready`) while
# `.claude/scripts/` still holds an untracked `*.sh`.
#
# This is the disposal half of the rule `enforce_batch_via_script.sh`
# mandates: batch work must go through `.claude/scripts/<name>.sh`, but
# nothing ever asked what happens to that script afterwards, so every
# fanout was obliged to leave one behind. Fifteen accumulated over three
# months and made the local `lint` gate permanently red -- a gate nobody
# can read (refs #282).
#
# WHY at PR-open and not inside `ci.sh check`: a script under
# `.claude/scripts/` may legitimately be temporary -- written for
# something happening right now and not yet known to be permanent.
# Failing `check` would fire during that legitimate in-progress window.
# Opening a PR is the point where the question is genuinely due: the work
# is finished, so the script is either part of it (committed) or it was
# scratch (deleted).
#
# Scope: every `*.sh` anywhere under `.claude/scripts/`, `lib/` included
# -- that is exactly the set `ci.sh lint` covers, so "lints clean" and
# "survives the PR gate" stay the same question. Non-`.sh` files are out
# of scope: the convention, the lint target and the accumulation are all
# about shell scripts.
#
# Fail safe: if cwd is missing, is not a git repo, or has no
# `.claude/scripts/` directory, stay silent (never block on an
# unresolvable context).

set -uo pipefail

readonly SCRIPTS_SUBDIR=".claude/scripts"

deny() {
  local reason="$1"
  jq -n --arg m "${reason}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $m
    }
  }'
}

main() {
  local input cmd cwd
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  cwd="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
  [[ -z "${cmd}" ]] && return 0

  # Trigger only on PR-open / PR-ready.
  [[ "${cmd}" =~ gh[[:space:]]+pr[[:space:]]+(create|ready)([[:space:]]|$) ]] || return 0

  # Resolve repo root; fail safe (silent) if not a git repo.
  [[ -z "${cwd}" ]] && cwd="${PWD}"
  local root
  root="$(git -C "${cwd}" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [[ -d "${root}/${SCRIPTS_SUBDIR}" ]] || return 0

  # `-uall` lists individual files: the default collapses a wholly
  # untracked directory to one `?? dir/` entry, which would hide every
  # `.sh` inside a freshly created subdirectory.
  local untracked line path
  untracked=""
  while IFS= read -r line; do
    [[ "${line}" == '??'* ]] || continue
    path="${line#?? }"
    [[ "${path}" == *.sh ]] || continue
    untracked+="  ${path}"$'\n'
  done < <(git -C "${root}" status --porcelain -uall -- "${SCRIPTS_SUBDIR}" 2>/dev/null)

  [[ -z "${untracked}" ]] && return 0

  deny "Untracked shell scripts under ${SCRIPTS_SUBDIR}/ (this PR would leave them behind):
${untracked}Each one is either permanent tooling -- \`git add\` it so CI and the local \`lint\` gate see the same files -- or it was scratch for work now finished, in which case delete it. Fifteen such one-offs once accumulated unnoticed and kept local \`lint\` red for weeks (refs #282). Then re-open the PR."
  return 0
}

main "$@"
