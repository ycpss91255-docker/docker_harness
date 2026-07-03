#!/usr/bin/env bash
# check_prefer_dot_sh.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. When the command is a state-changing
# `docker <subcommand>` (build / run / exec / stop) or
# `docker compose <up|down|build|run|exec>` AND cwd has a root `justfile`
# that defines the matching recipe, BLOCKS with a message steering to
# `just <verb>`. When there is no justfile or no such recipe, forces a
# prompt (permissionDecision="ask") rather than letting the broader
# `Bash(docker:*)` allow rule pass silently.
#
# Why: base migrated container-ops from the retired `./build.sh` /
# `./run.sh` / `./exec.sh` / `./stop.sh` root wrappers to top-level
# `just` recipes (`just build|run|exec|stop|setup`). The recipe runs
# setup.sh (refresh .env / compose.yaml + language env + GPU/GUI
# detection) which raw docker skips, so running docker directly easily
# produces container state inconsistent with what the recipe would build.
#
# Subcommand → just recipe map:
#   docker build         → just build
#   docker run           → just run
#   docker exec          → just exec
#   docker stop          → just stop
#   docker compose up    → just run
#   docker compose down  → just stop
#   docker compose build → just build
#   docker compose run   → just run
#   docker compose exec  → just exec
#
# Out of scope (silent — fall through to other rules):
#   - Read-only subcommands (ps / images / version / inspect / logs / pull / ...)
#   - Destructive ones already in `permissions.ask` (rm / rmi / kill / push / ...)
#   - `make`-driven docker calls (make's subprocess; not visible to Claude)

set -uo pipefail

# recipe_defined <justfile> <verb> — true if the justfile defines a
# recipe named <verb>. Recipes can be `build:` or `build *args:` (or
# `build arg:`), so match a line starting with the verb followed by a
# space, a colon, or a `*` parameter marker.
recipe_defined() {
  local justfile="$1" verb="$2"
  grep -Eq "^${verb}( |:|\*)" "${justfile}" 2>/dev/null
}

main() {
  local input cmd cwd subcmd verb msg stripped
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  cwd="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
  [[ -z "${cwd}" ]] && cwd="${PWD}"
  [[ -z "${cmd}" ]] && return 0

  # Strip leading env-prefix(es): `VAR=value [VAR=value ...] cmd ...`.
  stripped="${cmd}"
  while [[ "${stripped}" =~ ^[A-Z_][A-Z0-9_]*=[^[:space:]]+[[:space:]]+ ]]; do
    stripped="${stripped#"${BASH_REMATCH[0]}"}"
  done

  subcmd=""
  verb=""
  if [[ "${stripped}" =~ ^docker[[:space:]]+(build|run|exec|stop)([[:space:]]|$) ]]; then
    subcmd="docker ${BASH_REMATCH[1]}"
    verb="${BASH_REMATCH[1]}"
  elif [[ "${stripped}" =~ ^docker[[:space:]]+compose[[:space:]]+(up|down|build|run|exec)([[:space:]]|$) ]]; then
    subcmd="docker compose ${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[1]}" in
      up|run) verb="run" ;;
      down)   verb="stop" ;;
      build)  verb="build" ;;
      exec)   verb="exec" ;;
    esac
  else
    return 0
  fi

  local justfile="${cwd}/justfile"
  if [[ -f "${justfile}" ]] && recipe_defined "${justfile}" "${verb}"; then
    # shellcheck disable=SC2016  # backticks are literal markdown, not command substitution
    msg="$(printf '%s — use `just %s` instead. cwd has a `justfile` with a `%s` recipe; the recipe runs setup.sh (refresh .env / compose.yaml + language env + GPU/GUI detection) which raw docker skips, so running docker directly easily produces container state inconsistent with the recipe.' \
      "${subcmd}" "${verb}" "${verb}")"
    jq -n --arg m "${msg}" '{
      systemMessage: $m,
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $m
      }
    }'
    return 0
  fi

  # shellcheck disable=SC2016  # backticks are literal markdown, not command substitution
  msg="$(printf '%s — no `just %s` recipe here (cwd=%s): sure you want raw docker? Container-ops normally go through `just build` / `just run` / `just exec` / `just stop` recipes.' \
    "${subcmd}" "${verb}" "${cwd}")"
  jq -n --arg m "${msg}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $m
    }
  }'
}

main "$@"
