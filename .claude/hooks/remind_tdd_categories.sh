#!/usr/bin/env bash
# remind_tdd_categories.sh — Claude Code PostToolUse hook
#
# Fires on Edit / Write / MultiEdit. When the touched file falls into a
# TDD-relevant category (shell logic / entrypoint / Dockerfile / compose /
# CI workflow / lint rules), emit a JSON systemMessage reminding Claude
# which of the 4 test categories (smoke / unit / integration / lint) the
# change is expected to cover. Non-blocking — exit 0.
#
# Mapping is intentionally a soft reminder, not enforcement: the hook does
# NOT verify that tests were actually written. It just nags by re-injecting
# the relevant row of the 變更類型 → 測試類別 table from CLAUDE.md, so the
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

# Build a `;`-joined reminder string with one clause per applicable
# TDD test category for the repo. Lint always applies; the other
# three (smoke / unit / integration) apply iff the matching
# `test/<cat>/` dir exists under repo_root. Fallback: if repo_root
# is empty OR none of the three test subdirs exist, claim all three
# applicable so the generic guidance still fires (matches the
# pre-#75 behaviour for fresh / unstructured repos).
build_reminder() {
  local key="$1"
  local repo_root="$2"
  local has_smoke=0 has_unit=0 has_integration=0
  if [[ -n "${repo_root}" ]]; then
    [[ -d "${repo_root}/test/smoke" ]] && has_smoke=1
    [[ -d "${repo_root}/test/unit" ]] && has_unit=1
    [[ -d "${repo_root}/test/integration" ]] && has_integration=1
  fi
  if (( has_smoke == 0 && has_unit == 0 && has_integration == 0 )); then
    has_smoke=1; has_unit=1; has_integration=1
  fi

  local smoke="" unit="" integration="" lint=""
  case "${key}" in
    entrypoint)
      smoke="Smoke 必須（容器起來後核心 path 跑得過）"
      lint="Lint 必須（ShellCheck）"
      unit="視函式拆分補 Unit"
      integration="視 multi-container 補 Integration"
      ;;
    hadolint)
      lint="Lint 必須：跑一次全套（just build test / just test，或 make -C .claude/test test）確認既有檔案沒有新 violation"
      smoke="Smoke 通常 N/A"
      unit="Unit 通常 N/A"
      integration="Integration 通常 N/A"
      ;;
    workflow)
      integration="Integration 必須（PR 跑一次驗證新 workflow 真的觸發）"
      smoke="視觸發點補 Smoke"
      lint="Lint（actionlint 若有）"
      ;;
    compose)
      integration="Integration 必須（multi-container 協同行為）"
      smoke="視單容器影響補 Smoke"
      lint="視 compose lint 工具"
      ;;
    dockerfile)
      smoke="Smoke 必須（container 起得來、核心指令可用）"
      lint="Lint 必須（Hadolint）"
      integration="視 build flow 補 Integration"
      ;;
    shell)
      unit="Unit 必須（隔離函式邏輯，bats-mock）"
      lint="Lint 必須（ShellCheck）"
      smoke="視 path 影響補 Smoke"
      integration="視流程影響補 Integration"
      ;;
  esac

  local parts=""
  (( has_smoke )) && [[ -n "${smoke}" ]] && parts+="${smoke}；"
  (( has_unit )) && [[ -n "${unit}" ]] && parts+="${unit}；"
  (( has_integration )) && [[ -n "${integration}" ]] && parts+="${integration}；"
  [[ -n "${lint}" ]] && parts+="${lint}；"
  printf '%s' "${parts%；}"
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
      category="entrypoint / 容器啟動行為"
      key="entrypoint"
      ;;
    *.hadolint.yaml|*/.shellcheckrc|*.shellcheckrc)
      category="lint 規則調整"
      key="hadolint"
      ;;
    */.github/workflows/*.yaml|*/.github/workflows/*.yml)
      category="CI workflow / reusable workflow"
      key="workflow"
      ;;
    */compose.yaml)
      category="compose / multi-container 行為"
      key="compose"
      ;;
    */Dockerfile|*/Dockerfile.*|*Dockerfile)
      category="Dockerfile（stage / COPY / ENV / ARG 等）"
      key="dockerfile"
      ;;
    *.sh)
      category="shell 函式 / 腳本邏輯"
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
    msg="$(printf 'TDD reminder — 剛動到 %s（類別：%s）\n%s\n對照表：CLAUDE.md「測試分類（TDD 必須涵蓋的 4 個面向）」\n\nApplicable instincts (.claude/instincts.yaml):\n%s' \
      "${file_path}" "${category}" "${reminder}" "${instincts}")"
  else
    msg="$(printf 'TDD reminder — 剛動到 %s（類別：%s）\n%s\n對照表：CLAUDE.md「測試分類（TDD 必須涵蓋的 4 個面向）」' \
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
