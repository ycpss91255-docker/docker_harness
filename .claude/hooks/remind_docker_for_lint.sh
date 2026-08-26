#!/usr/bin/env bash
# remind_docker_for_lint.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. When the command directly invokes a
# lint / test tool (bats / shellcheck / hadolint / kcov) outside of
# a recognised wrapper, remind that lint/test must run via Docker.
# Non-blocking (always exit 0).
#
# Why: CLAUDE.md "驗證一律走 Docker" (verify-via-Docker) forbids bare host invocations —
# host bats-mock / bats-support / shellcheck versions may differ from
# CI, producing inconsistent results. CI's reusable workflow runs the
# same docker image we use locally.
#
# Wrapper list: by default, recognises these substring patterns as
# "already wrapped, no reminder":
#   docker run / docker exec / docker compose
#   just -f justfile.ci / just test / just build / just lint
#   make -f Makefile.ci   (legacy; tolerated during the make->just
#                          transition until downstream .base flips, #202)
#   ./build.sh
#   just -f .claude/test/justfile
#
# Override per-repo: drop a `.claude/lint_wrappers.txt` next to
# settings.json — one substring pattern per line, blank/`#`-prefixed
# lines ignored. When the file is present it REPLACES the default
# list (full override, not append). Useful for downstream forks that
# wrap lint differently (e.g. coreSAM uses `make -C .claude` instead
# of `make -f Makefile.ci`).

set -uo pipefail

main() {
  local input cmd msg
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"

  [[ -z "${cmd}" ]] && return 0

  local -a wrappers=()
  local wrappers_file="${CLAUDE_PROJECT_DIR:-}/.claude/lint_wrappers.txt"
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -f "${wrappers_file}" ]]; then
    local line
    while IFS= read -r line || [[ -n "${line}" ]]; do
      # strip leading whitespace
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -z "${line}" || "${line}" == \#* ]] && continue
      wrappers+=("${line}")
    done < "${wrappers_file}"
  fi

  if (( ${#wrappers[@]} == 0 )); then
    wrappers=(
      "docker run"
      "docker exec"
      "docker compose"
      "just -f justfile.ci"
      "just test"
      "just build"
      "just lint"
      "make -f Makefile.ci"
      "./build.sh"
      "just -f .claude/test/justfile"
    )
  fi

  local w
  for w in "${wrappers[@]}"; do
    case "${cmd}" in
      *"${w}"*) return 0 ;;
    esac
  done

  [[ "${cmd}" =~ (^|[\;\&\|][[:space:]]*)(bats|shellcheck|hadolint|kcov)([[:space:]]|$) ]] || return 0

  local tool="${BASH_REMATCH[2]}"
  msg="$(printf '"驗證一律走 Docker" (verify-via-Docker) reminder: detected a direct %s invocation; results may differ from CI (local bats-mock / shellcheck versions may vary). Use just test / just test lint (base), just build test (downstream), or just -f .claude/test/justfile test (docker_harness; legacy ./build.sh test still accepted).' "${tool}")"

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
