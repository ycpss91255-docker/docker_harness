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
