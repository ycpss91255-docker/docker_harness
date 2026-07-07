#!/usr/bin/env bash
# remind_main_sync.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before `gh pr merge` (any flag combination). Emits a JSON
# systemMessage reminding the user to `git pull --ff-only origin main`
# on the main checkout after the merge lands, so the local main keeps
# tracking origin/main HEAD instead of freezing in place.
#
# Non-blocking (always exit 0). Two message variants:
#   - With --auto: merge is queued; remind to pull after CI passes
#   - Without --auto: merge is immediate; remind to pull right after
#
# Why: CLAUDE.md「Git 工作流程 > 主 checkout 狀態」(Git workflow > main
# checkout state) requires the main checkout to always sit at origin/main
# HEAD — meaning "continuously ff-tracking", not "frozen at some commit".
# PR #89 hit exactly this: local main lagged several PRs behind, a worktree
# branch was started from that stale base, and a forced rebase followed.
#
# Trigger pattern: `gh pr merge` must appear in the command as an actual
# subcommand, not as a substring inside a quoted string (avoids a false
# positive from a commit message like `git commit -m "...gh pr merge..."`).
# Implementation:
#   1. use sed to strip double-/single-quoted regions (simple unnested case)
#   2. run the trigger regex on the cleaned string
#   3. add a command-boundary anchor (start, or after ; & | $( ) so that
#      `gh pr merge` only matches as an actual subcommand
# Not limited to `--squash` / `--merge` / `--rebase`; any merge mode fires.
# Skip read-only `gh pr view` / `gh pr checks` etc.

set -uo pipefail

# Strip outer-level double-quoted and single-quoted regions so a literal
# `gh pr merge` inside a commit message / -m argument / heredoc body
# does not falsely trigger the reminder. Conservative: handles
# unnested quotes; mixed nesting / escaped quotes degrade gracefully
# (worst case: a false positive survives -- never a false negative).
strip_quoted_regions() {
  local s="$1"
  s="$(printf '%s' "${s}" | sed -E 's/"[^"]*"//g')"
  s="$(printf '%s' "${s}" | sed -E "s/'[^']*'//g")"
  printf '%s' "${s}"
}

main() {
  local input cmd cleaned msg variant
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"

  [[ -z "${cmd}" ]] && return 0

  cleaned="$(strip_quoted_regions "${cmd}")"

  # `gh pr merge` must sit at a command boundary in `cleaned`: start of
  # string, or right after one of `;` `&` `|` `$(`, allowing whitespace
  # between the boundary and `gh`. This prevents matches mid-token (e.g.
  # the substring of a removed quoted region's surroundings).
  if ! [[ "${cleaned}" =~ (^|[\;\&\|]|\$\()[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$) ]]; then
    return 0
  fi

  if [[ "${cleaned}" =~ --auto([[:space:]]|$) ]]; then
    variant="queued"
    msg="Auto-merge queued. After CI passes and GitHub completes the merge, run \`git -C \$(git rev-parse --show-toplevel 2>/dev/null) pull --ff-only origin main\` (or the same from your main checkout) to keep local main tracking origin/main HEAD. See CLAUDE.md 'Git 工作流程 > 主 checkout 狀態' (Git workflow > main checkout state)."
  else
    variant="immediate"
    msg="PR merged. Run \`git pull --ff-only origin main\` on your main checkout now so local main keeps tracking origin/main HEAD (don't let it freeze behind). See CLAUDE.md 'Git 工作流程 > 主 checkout 狀態' (Git workflow > main checkout state)."
  fi

  jq -n --arg m "${msg}" --arg v "${variant}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: ($m + " [variant=" + $v + "]")
    }
  }'

  return 0
}

main "$@"
