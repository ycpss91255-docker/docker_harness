#!/usr/bin/env bats
#
# Acceptance level (ISTQB, UAT/OAT): what a consumer session actually
# receives when it loads this .claude/ framework. Not a hook's internal
# logic (that is unit) but the delivered whole hanging together: every
# registered hook resolves to a real script, every skill symlink points
# at a real SKILL.md. A rename that updates a hook but forgets
# settings.json, or a skill move that leaves a dangling symlink, is a
# consumer-facing breakage no unit spec catches -- it fails here.

load '../lib/test_helper'

@test "acceptance: every settings.json-registered hook command resolves to a file" {
  local missing=""
  while IFS= read -r cmd; do
    [[ -z "${cmd}" ]] && continue
    local path="${cmd/\$CLAUDE_PROJECT_DIR/${PROJECT_ROOT}}"
    [[ -f "${path}" ]] || missing+="  ${path}"$'\n'
  done < <(jq -r '.hooks[][].hooks[].command' "${PROJECT_ROOT}/.claude/settings.json")
  [[ -z "${missing}" ]] || {
    echo "settings.json registers hooks whose script is missing:"$'\n'"${missing}"
    return 1
  }
}

@test "acceptance: every .claude/skills symlink resolves to a SKILL.md" {
  local dangling=""
  for link in "${PROJECT_ROOT}"/.claude/skills/*; do
    [[ -e "${link}" ]] || continue   # empty-glob guard
    [[ -f "${link}/SKILL.md" ]] || dangling+="  ${link}"$'\n'
  done
  [[ -z "${dangling}" ]] || {
    echo "dangling repo-owned skill symlinks (expect ../../.agents/skills/<name>/SKILL.md):"$'\n'"${dangling}"
    return 1
  }
}

@test "acceptance: every enforce_*.sh hook is armed in settings.json" {
  # The complement of the stanza above, and the failure it catches is
  # worse: a registration pointing at nothing is loud, while an
  # enforcement hook that ships UNREGISTERED is a gate that silently
  # never fires -- the session gets no protection and no error either
  # (refs #282, where the gate against untracked one-off scripts is
  # only real if a consumer session actually runs it).
  local registered unarmed=""
  registered="$(jq -r '.hooks[][].hooks[].command' "${PROJECT_ROOT}/.claude/settings.json")"
  for h in "${PROJECT_ROOT}"/.claude/hooks/enforce_*.sh; do
    [[ -e "${h}" ]] || continue   # empty-glob guard
    grep -qF -- "/$(basename "${h}")" <<< "${registered}" \
      || unarmed+="  ${h}"$'\n'
  done
  [[ -z "${unarmed}" ]] || {
    echo "enforcement hooks that exist but are registered nowhere:"$'\n'"${unarmed}"
    return 1
  }
}

@test "acceptance: no Bash PreToolUse hook blocks or prompts on raw docker / docker compose" {
  # Owner decision 2026-11-18: testing often runs `docker run` (and the
  # rest of the container verbs) directly, so no registered hook may
  # deny or ask on them, even in a repo whose justfile has matching
  # build / run / exec / stop recipes.
  local repo blocked=""
  repo="$(mktemp -d)"
  printf 'build *args:\n\t:\nrun *args:\n\t:\nexec *args:\n\t:\nstop:\n\t:\n' > "${repo}/justfile"
  local -a cmds=(
    "docker build -t foo ."
    "docker run --rm foo"
    "docker exec -it foo bash"
    "docker stop foo"
    "docker compose up -d"
    "docker compose down"
    "docker compose build"
    "docker compose run --rm foo"
    "docker compose exec foo bash"
  )
  local hooks
  hooks="$(jq -r '.hooks.PreToolUse[] | select(.matcher | test("Bash")) | .hooks[].command' \
    "${PROJECT_ROOT}/.claude/settings.json")"
  local cmd hook path input out decision
  for cmd in "${cmds[@]}"; do
    input="$(jq -nc --arg c "${cmd}" --arg d "${repo}" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
    while IFS= read -r hook; do
      [[ -z "${hook}" ]] && continue
      path="${hook/\$CLAUDE_PROJECT_DIR/${PROJECT_ROOT}}"
      out="$(cd "${repo}" && CLAUDE_PROJECT_DIR="${PROJECT_ROOT}" "${path}" <<< "${input}" 2>/dev/null || true)"
      decision="$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "${out}" 2>/dev/null || true)"
      if [[ "${decision}" == "deny" || "${decision}" == "ask" ]]; then
        blocked+="  ${decision}: $(basename "${path}") on '${cmd}'"$'\n'
      fi
    done <<< "${hooks}"
  done
  rm -rf "${repo}"
  [[ -z "${blocked}" ]] || {
    echo "hooks that block or prompt on raw docker commands:"$'\n'"${blocked}"
    return 1
  }
}
