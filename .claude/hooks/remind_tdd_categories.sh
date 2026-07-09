#!/usr/bin/env bash
# remind_tdd_categories.sh — Claude Code PostToolUse hook
#
# Fires on Edit / Write / MultiEdit. When the touched file falls into a
# TDD-relevant category (shell logic / entrypoint / Dockerfile / compose /
# CI workflow / lint rules), emit a JSON systemMessage reminding Claude
# which tests the change is expected to cover, in the ISTQB three-axis
# model (ADR-00000013): levels (unit / integration / system / acceptance),
# types (smoke / e2e / regression), and static analysis (lint). Smoke is a
# TYPE applied at the system level, not a level of its own. Non-blocking —
# exit 0.
#
# Mapping is intentionally a soft reminder, not enforcement: the hook does
# NOT verify that tests were actually written. It just nags by re-injecting
# the relevant row of the 變更類型 → 測試類別 (change type → test category)
# table from CLAUDE.md, so the
# rule stays in context the moment a relevant file is touched.
#
# Skip list:
#   - .md / .bats / TEST.md — the test or doc itself; user is doing the
#     reminding side already
#   - .claude/ internals — avoid firing when editing this hook itself
#   - .git / node_modules / coverage / cache — irrelevant
#   - generated artifacts (.env, derived compose.yaml in repo roots) are
#     not skipped here — Claude rarely edits them by hand; if it does,
#     a reminder is still cheap

set -uo pipefail

# Walk up from a directory looking for a repo-root marker (Dockerfile,
# justfile.ci / Makefile.ci, .base/, template/, init.sh). Returns the
# first matching ancestor or empty. Scopes TDD-capability detection to
# the relevant downstream repo even when the file lives inside a
# docker_harness subtree (refs #75; justfile.ci added #202 / base#573;
# root justfile added #220 — base/downstream now use a root justfile).
detect_repo_root() {
  local dir="$1"
  while [[ "${dir}" != "/" && "${dir}" != "." && -n "${dir}" ]]; do
    if [[ -e "${dir}/Dockerfile" || -e "${dir}/justfile" \
          || -e "${dir}/justfile.ci" || -e "${dir}/Makefile.ci" \
          || -d "${dir}/.base" || -d "${dir}/template" \
          || -e "${dir}/init.sh" ]]; then
      printf '%s' "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  return 1
}

# Build a `;`-joined reminder string with one clause per applicable ISTQB
# test LEVEL for the repo, plus static analysis. Static (lint) always
# applies; the levels (unit / integration / system) apply iff the matching
# `test/bats/<level>/` dir exists under repo_root (base / downstream moved
# to test/bats/<level>/ post-taxonomy, ADR-00000013 / base ADR-00000018).
# Smoke is emitted as a TYPE inside the system clause, not a level. Fallback:
# if repo_root is empty OR none of the level dirs exist, claim all
# applicable so the generic guidance still fires (fresh / unmigrated repos).
build_reminder() {
  local key="$1"
  local repo_root="$2"
  local has_unit=0 has_integration=0 has_system=0
  if [[ -n "${repo_root}" ]]; then
    [[ -d "${repo_root}/test/bats/unit" ]] && has_unit=1
    [[ -d "${repo_root}/test/bats/integration" ]] && has_integration=1
    [[ -d "${repo_root}/test/bats/system" ]] && has_system=1
  fi
  if (( has_unit == 0 && has_integration == 0 && has_system == 0 )); then
    has_unit=1; has_integration=1; has_system=1
  fi

  local unit="" integration="" system="" lint=""
  case "${key}" in
    entrypoint)
      system="System required (Smoke type: core path runs once the container is up)"
      lint="Static: ShellCheck required"
      unit="Add Unit if functions are split out"
      integration="Add Integration for multi-container"
      ;;
    hadolint)
      lint="Static: run the full suite once (just build test / just test, or just -f .claude/test/justfile test) to confirm existing files have no new violations"
      system="System usually N/A"
      unit="Unit usually N/A"
      integration="Integration usually N/A"
      ;;
    workflow)
      system="System required (E2E type: run the PR once to verify the new workflow actually triggers)"
      integration="Add Integration if it coordinates multiple jobs"
      lint="Static: actionlint if available"
      ;;
    compose)
      integration="Integration required (multi-container coordinated behaviour)"
      system="Add System if single-container behaviour is affected"
      lint="Static: compose lint tool if available"
      ;;
    dockerfile)
      system="System required (Smoke type: container builds + comes up, core commands work)"
      lint="Static: Hadolint required"
      integration="Add Integration for the build flow"
      ;;
    shell)
      unit="Unit required (isolate function logic, bats-mock)"
      lint="Static: ShellCheck required"
      system="Add System if the runtime path is affected"
      integration="Add Integration if the flow is affected"
      ;;
  esac

  local parts=""
  (( has_unit )) && [[ -n "${unit}" ]] && parts+="${unit}; "
  (( has_integration )) && [[ -n "${integration}" ]] && parts+="${integration}; "
  (( has_system )) && [[ -n "${system}" ]] && parts+="${system}; "
  [[ -n "${lint}" ]] && parts+="${lint}; "
  printf '%s' "${parts%; }"
}

main() {
  local input file_path category key reminder repo_root
  input="$(cat)"
  file_path="$(printf '%s' "${input}" | jq -r '
    .tool_input.file_path
    // .tool_response.filePath
    // empty
  ' 2>/dev/null)"

  [[ -z "${file_path}" || ! -f "${file_path}" ]] && return 0

  case "${file_path}" in
    */.git/*|*/node_modules/*|*/coverage/*|*/.cache/*) return 0 ;;
    */.claude/*) return 0 ;;
    *.md|*.bats) return 0 ;;
  esac

  category=""
  key=""

  case "${file_path}" in
    */entrypoint.sh)
      category="entrypoint / container startup behaviour"
      key="entrypoint"
      ;;
    *.hadolint.yaml|*/.shellcheckrc|*.shellcheckrc)
      category="lint rule change"
      key="hadolint"
      ;;
    */.github/workflows/*.yaml|*/.github/workflows/*.yml)
      category="CI workflow / reusable workflow"
      key="workflow"
      ;;
    */compose.yaml)
      category="compose / multi-container behaviour"
      key="compose"
      ;;
    */Dockerfile|*/Dockerfile.*|*Dockerfile)
      category="Dockerfile (stage / COPY / ENV / ARG, etc.)"
      key="dockerfile"
      ;;
    *.sh)
      category="shell function / script logic"
      key="shell"
      ;;
  esac

  [[ -z "${category}" ]] && return 0

  repo_root="$(detect_repo_root "$(dirname "${file_path}")")" || repo_root=""

  reminder="$(build_reminder "${key}" "${repo_root}")"

  # PoC integration with .claude/instincts.yaml (#95): query the
  # machine-readable convention store for instincts that apply to this
  # file, and append them under the TDD nag. Soft failure -- absent
  # query helper / instincts file / no match all just skip the append.
  local instinct_query="${CLAUDE_PROJECT_DIR:-${PWD}}/.claude/scripts/instinct-query.sh"
  local instincts=""
  if [[ -x "${instinct_query}" ]]; then
    instincts="$("${instinct_query}" file_edit "${file_path}" 2>/dev/null || true)"
  fi

  local msg
  if [[ -n "${instincts}" ]]; then
    msg="$(printf 'TDD reminder — just touched %s (category: %s)\n%s\nReference: CONTEXT.md §11 test taxonomy (ISTQB levels / types / static analysis, ADR-00000013)\n\nApplicable instincts (.claude/instincts.yaml):\n%s' \
      "${file_path}" "${category}" "${reminder}" "${instincts}")"
  else
    msg="$(printf 'TDD reminder — just touched %s (category: %s)\n%s\nReference: CONTEXT.md §11 test taxonomy (ISTQB levels / types / static analysis, ADR-00000013)' \
      "${file_path}" "${category}" "${reminder}")"
  fi

  jq -n --arg m "${msg}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $m
    }
  }'

  return 0
}

main "$@"
