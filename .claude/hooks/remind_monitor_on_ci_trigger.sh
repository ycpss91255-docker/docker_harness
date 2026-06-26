#!/usr/bin/env bash
# remind_monitor_on_ci_trigger.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. When the command triggers a new CI run
# (`gh workflow run ...` for workflow_dispatch, or `gh run rerun ...` for
# re-running a previous run), emit a JSON systemMessage reminding to
# Monitor the resulting run via wait-tag-ci.sh / /wait-pr-ci instead of
# sleep-polling. Non-blocking (always exit 0).
#
# Why: sibling of remind_ci_auto_merge.sh (which only fires on `gh pr
# create`). Without this hook, agents re-run a failed workflow or
# dispatch one manually and then forget to arm a Monitor — CI results
# go unchecked or get sleep-polled, burning context.
#
# Trigger patterns:
#   - gh[[:space:]]+workflow[[:space:]]+run (workflow_dispatch — always
#     tag/branch-scoped, suggest wait-tag-ci.sh)
#   - gh[[:space:]]+run[[:space:]]+rerun (re-run — can be PR or
#     tag-scoped; mention both so the agent picks)
#
# Refs: ycpss91255-docker/docker_harness#154

set -uo pipefail

main() {
  local input cmd fires msg
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"

  [[ -z "${cmd}" ]] && return 0

  if [[ "${cmd}" =~ gh[[:space:]]+workflow[[:space:]]+run([[:space:]]|$) ]]; then
    fires="workflow"
  elif [[ "${cmd}" =~ gh[[:space:]]+run[[:space:]]+rerun([[:space:]]|$) ]]; then
    fires="rerun"
  else
    return 0
  fi

  case "${fires}" in
    workflow)
      msg="workflow_dispatch 提醒：開完別 sleep 輪詢 — 用 wait-tag-ci.sh (.claude/scripts/wait-tag-ci.sh) 把 dispatched run 跑到綠燈再走。內部 Monitor + until poll 30s，不會 burn context。"
      ;;
    rerun)
      msg="re-run 提醒：開完別 sleep 輪詢 — PR-scoped re-run 用 /wait-pr-ci skill (.claude/skills/wait-pr-ci/SKILL.md)，tag/branch-scoped re-run 用 wait-tag-ci.sh (.claude/scripts/wait-tag-ci.sh)。內部都走 Monitor + until poll，不會 burn context。"
      ;;
  esac

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
