#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

# verify.sh — unified pre-commit / pre-PR verification loop.
#
# Runs the project's change-complete checklist (CLAUDE.md「變更完成
# checklist」) in sequence and prints a markdown summary at the end.
# Stops on the first hard failure (shellcheck / hadolint / bats) unless
# --continue-on-fail; soft phases (tree audit, TEST.md drift, doc-scan,
# diff stats) warn and continue.
#
# Phases (h = hard, s = soft, i = info-only):
#   [h] shellcheck    just -f .claude/test/justfile lint
#   [h] hadolint      just -f .claude/test/justfile hadolint
#   [h] bats          just -f .claude/test/justfile test
#   [s] tree-audit    .claude/scripts/check-claude-md-tree.sh
#   [s] test-md       TEST.md per-section drift vs *.bats @test
#   [s] doc-scan      emoji + AI attribution scan over changed files
#   [i] diff-stats    git diff origin/main..HEAD --stat
#
# Usage:
#   verify.sh [--dry-run] [--continue-on-fail] [--phase <name>]
#             [--repo-root <path>] [--base <ref>]
#
# Options:
#   --dry-run            Print the phase plan and exit 0; run nothing.
#   --continue-on-fail   Keep running soft phases even after a hard
#                        phase fails. Final exit code still reflects
#                        the worst phase.
#   --phase <name>       Run only one phase. Repeatable.
#   --repo-root <path>   Override repo root (default: ${CLAUDE_PROJECT_DIR}
#                        or git rev-parse --show-toplevel).
#   --base <ref>         Base ref for diff-stats + doc-scan changed-file
#                        set. Default: origin/main.
#
# Environment overrides (advanced — testing only):
#   VERIFY_LINT_CMD       Override shellcheck-phase command. Default:
#                         just -f <repo>/.claude/test/justfile lint
#   VERIFY_HADOLINT_CMD   Override hadolint-phase command. Default:
#                         just -f <repo>/.claude/test/justfile hadolint
#   VERIFY_TEST_CMD       Override bats-phase command. Default:
#                         just -f <repo>/.claude/test/justfile test
#
# Exit:
#   0  All requested phases passed.
#   1  At least one phase failed (hard or soft). Hard fails short-circuit
#      later phases unless --continue-on-fail; soft fails record in the
#      summary table and let the run continue, but still surface as
#      exit 1 so `verify && commit` is a meaningful gate.
#   2  Usage / arg error.

set -uo pipefail

_VERIFY_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=lib/log.sh disable=SC1091
source "${_VERIFY_SCRIPT_DIR}/lib/log.sh"

readonly ALL_PHASES=(shellcheck hadolint bats tree-audit test-md doc-scan diff-stats)
readonly HARD_PHASES=(shellcheck hadolint bats)

usage() {
  sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

is_hard() {
  local name="$1" p
  for p in "${HARD_PHASES[@]}"; do
    [[ "${p}" == "${name}" ]] && return 0
  done
  return 1
}

in_array() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

run_shellcheck() {
  if [[ -n "${VERIFY_LINT_CMD:-}" ]]; then
    ( eval "${VERIFY_LINT_CMD}" )
    return $?
  fi
  just -f "${REPO_ROOT}/.claude/test/justfile" lint
}

run_hadolint() {
  if [[ -n "${VERIFY_HADOLINT_CMD:-}" ]]; then
    ( eval "${VERIFY_HADOLINT_CMD}" )
    return $?
  fi
  just -f "${REPO_ROOT}/.claude/test/justfile" hadolint
}

run_bats() {
  if [[ -n "${VERIFY_TEST_CMD:-}" ]]; then
    ( eval "${VERIFY_TEST_CMD}" )
    return $?
  fi
  just -f "${REPO_ROOT}/.claude/test/justfile" test
}

run_tree_audit() {
  "${REPO_ROOT}/.claude/scripts/check-claude-md-tree.sh" "${REPO_ROOT}/CLAUDE.md"
}

run_test_md() {
  local test_md="${REPO_ROOT}/doc/test/TEST.md"
  [[ -f "${test_md}" ]] || { _log_info verify lint_pass kind=test-md detail=missing; return 0; }

  local drifts=0 line rel claimed actual file
  while IFS= read -r line; do
    rel="$(printf '%s' "${line}" | sed -E 's/^### (test\/.+\.bats) \(([0-9]+)\)$/\1/')"
    claimed="$(printf '%s' "${line}" | sed -E 's/^### (test\/.+\.bats) \(([0-9]+)\)$/\2/')"
    file="${REPO_ROOT}/.claude/hooks/${rel}"
    [[ -f "${file}" ]] || file="${REPO_ROOT}/${rel}"
    if [[ ! -f "${file}" ]]; then
      _log_warn verify drift_detected kind=test-md file="${rel}" reason=not-found
      drifts=$((drifts + 1))
      continue
    fi
    actual="$(grep -c '^@test' "${file}" || true)"
    if [[ "${claimed}" != "${actual}" ]]; then
      _log_warn verify drift_detected kind=test-md file="${rel}" claimed="${claimed}" actual="${actual}"
      drifts=$((drifts + 1))
    fi
  done < <(grep -hE '^### test/.+\.bats \([0-9]+\)$' "${REPO_ROOT}"/doc/test/*.md 2>/dev/null || true)

  if (( drifts > 0 )); then
    _log_err verify lint_fail kind=test-md count="${drifts}"
    return 1
  fi
  _log_info verify lint_pass kind=test-md
}

changed_files_since_base() {
  local base="$1"
  if git -C "${REPO_ROOT}" rev-parse --verify --quiet "${base}" >/dev/null 2>&1; then
    git -C "${REPO_ROOT}" diff --name-only "${base}"..HEAD
    git -C "${REPO_ROOT}" diff --name-only HEAD
    git -C "${REPO_ROOT}" ls-files --others --exclude-standard
  else
    git -C "${REPO_ROOT}" ls-files --others --exclude-standard
    git -C "${REPO_ROOT}" diff --name-only HEAD
  fi
}

run_doc_scan() {
  local base="$1"
  local files file hits=0
  files="$(changed_files_since_base "${base}" | sort -u)"
  [[ -z "${files}" ]] && { _log_info verify lint_pass kind=doc-scan base="${base}" reason=no-changes; return 0; }

  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    local abs="${REPO_ROOT}/${file}"
    [[ -f "${abs}" ]] || continue
    case "${abs}" in
      */CLAUDE.md|*/.claude/commands/*.md|*/.claude/skills/*/SKILL.md) continue ;;
      */doc/test/TEST.md|*/doc/changelog/CHANGELOG.md) continue ;;
      */.claude/hooks/test/*) continue ;;
      */.claude/instincts.yaml) continue ;;
    esac
    if file --mime "${abs}" 2>/dev/null | grep -qE 'charset=binary'; then
      continue
    fi
    if grep -qiE 'Generated with (\[)?Claude Code|Co-Authored-By:[[:space:]]*Claude' \
      "${abs}" 2>/dev/null; then
      _log_warn verify drift_detected kind=ai-attribution file="${file}"
      hits=$((hits + 1))
    fi
  done <<< "${files}"

  if (( hits > 0 )); then
    _log_err verify lint_fail kind=ai-attribution count="${hits}"
    return 1
  fi
  _log_info verify lint_pass kind=doc-scan base="${base}"
}

run_diff_stats() {
  local base="$1"
  if git -C "${REPO_ROOT}" rev-parse --verify --quiet "${base}" >/dev/null 2>&1; then
    git -C "${REPO_ROOT}" diff --stat "${base}"..HEAD || true
  else
    _log_warn verify drift_detected kind=diff-stats base="${base}" reason=missing-ref
  fi
}

run_phase() {
  local name="$1" base="$2"
  case "${name}" in
    shellcheck) run_shellcheck ;;
    hadolint)   run_hadolint ;;
    bats)       run_bats ;;
    tree-audit) run_tree_audit ;;
    test-md)    run_test_md ;;
    doc-scan)   run_doc_scan "${base}" ;;
    diff-stats) run_diff_stats "${base}" ;;
    *) _log_fatal verify unrecognised_arg phase="${name}"; return 2 ;;
  esac
}

main() {
  local dry_run=0
  local continue_on_fail=0
  local base="origin/main"
  local repo_root_override=""
  local phases=()

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --dry-run) dry_run=1; shift ;;
      --continue-on-fail) continue_on_fail=1; shift ;;
      --phase)
        [[ -n "${2:-}" ]] || { _log_fatal verify precondition_missing arg=--phase reason=needs-a-name; usage; exit 2; }
        phases+=("$2"); shift 2 ;;
      --repo-root)
        [[ -n "${2:-}" ]] || { _log_fatal verify precondition_missing arg=--repo-root reason=needs-a-path; usage; exit 2; }
        repo_root_override="$2"; shift 2 ;;
      --base)
        [[ -n "${2:-}" ]] || { _log_fatal verify precondition_missing arg=--base reason=needs-a-ref; usage; exit 2; }
        base="$2"; shift 2 ;;
      *) _log_fatal verify unrecognised_arg arg="${1}"; usage; exit 2 ;;
    esac
  done

  if [[ -n "${repo_root_override}" ]]; then
    REPO_ROOT="${repo_root_override}"
  elif [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "${CLAUDE_PROJECT_DIR}" ]]; then
    REPO_ROOT="${CLAUDE_PROJECT_DIR}"
  else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
  [[ -d "${REPO_ROOT}" ]] || { _log_fatal verify precondition_missing path="${REPO_ROOT}" reason=not-a-dir; exit 2; }

  if [[ ${#phases[@]} -eq 0 ]]; then
    phases=("${ALL_PHASES[@]}")
  else
    local p
    for p in "${phases[@]}"; do
      if ! in_array "${p}" "${ALL_PHASES[@]}"; then
        _log_fatal verify unrecognised_arg phase="${p}" valid_phases="${ALL_PHASES[*]}"
        exit 2
      fi
    done
  fi

  if (( dry_run )); then
    printf 'verify (dry-run) — repo: %s, base: %s\n' "${REPO_ROOT}" "${base}"
    printf 'phases:\n'
    local p
    for p in "${phases[@]}"; do
      if is_hard "${p}"; then
        printf '  - %s [hard]\n' "${p}"
      else
        printf '  - %s\n' "${p}"
      fi
    done
    exit 0
  fi

  local statuses=()
  local hard_failed=0
  local any_failed=0
  local p status
  for p in "${phases[@]}"; do
    printf '\n### %s\n' "${p}"
    if (( hard_failed && ! continue_on_fail )); then
      statuses+=("${p}:skipped")
      printf '(skipped — previous hard phase failed; pass --continue-on-fail to proceed)\n'
      continue
    fi
    if run_phase "${p}" "${base}"; then
      status="pass"
    else
      status="fail"
      any_failed=1
      if is_hard "${p}"; then
        hard_failed=1
      fi
    fi
    statuses+=("${p}:${status}")
  done

  printf '\n## Verify summary\n\n'
  printf '| Phase | Status |\n|---|---|\n'
  for entry in "${statuses[@]}"; do
    local phase="${entry%%:*}"
    local s="${entry##*:}"
    printf '| %s | %s |\n' "${phase}" "${s}"
  done

  if (( any_failed )); then
    exit 1
  fi
  exit 0
}

main "$@"
