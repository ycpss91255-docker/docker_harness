#!/usr/bin/env bats

# Repo-owned skills are canonicalised under .agents/skills/<name>/ (real
# directories tracked in git) and surfaced to Claude Code via a symlink at
# .claude/skills/<name> -> ../../.agents/skills/<name>. Third-party
# (mattpocock/skills) skills are machine-local and intentionally NOT asserted
# here -- they are reinstalled via `npx skills@latest add mattpocock/skills`.
# Refs #210.

load '../lib/test_helper'

# Resolve the repo root from HOOKS_DIR (= <root>/.claude/hooks).
repo_root() {
  cd "${HOOKS_DIR}/../.." && pwd
}

# The repo-owned skills that must live canonically under .agents/skills/.
# Third-party skills are deliberately absent (machine-local).
REPO_OWNED_SKILLS=(
  auto-merge-on-green
  batch-mutation-pr
  gh-artifact-format
  parallel-agents
  plan-and-build
  proactive-optimization
  semver-bump
  skillification-candidates
  strategic-compact
  update-stale-pr
  wait-gh-state
  wait-pr-ci
)

@test "every repo-owned .claude/skills/<name> is a symlink to ../../.agents/skills/<name>" {
  local root; root="$(repo_root)"
  local name link
  for name in "${REPO_OWNED_SKILLS[@]}"; do
    local path="${root}/.claude/skills/${name}"
    [ -L "${path}" ] || { echo "not a symlink: .claude/skills/${name}" >&2; return 1; }
    link="$(readlink "${path}")"
    [ "${link}" = "../../.agents/skills/${name}" ] || {
      echo "bad symlink target for ${name}: ${link}" >&2; return 1; }
  done
}

@test "every repo-owned skill resolves its SKILL.md through the symlink" {
  local root; root="$(repo_root)"
  local name
  for name in "${REPO_OWNED_SKILLS[@]}"; do
    [ -f "${root}/.claude/skills/${name}/SKILL.md" ] || {
      echo "SKILL.md not reachable via symlink: ${name}" >&2; return 1; }
  done
}

@test "every repo-owned skill canonical dir is a real directory under .agents/skills" {
  local root; root="$(repo_root)"
  local name
  for name in "${REPO_OWNED_SKILLS[@]}"; do
    local canon="${root}/.agents/skills/${name}"
    { [ -d "${canon}" ] && [ ! -L "${canon}" ]; } || {
      echo "canonical store not a real dir: .agents/skills/${name}" >&2; return 1; }
    [ -f "${canon}/SKILL.md" ] || {
      echo "canonical SKILL.md missing: ${name}" >&2; return 1; }
  done
}
