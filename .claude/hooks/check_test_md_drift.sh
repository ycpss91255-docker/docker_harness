#!/usr/bin/env bash
# check_test_md_drift.sh — Claude Code PostToolUse hook
#
# Fires on Edit / Write / MultiEdit. When the touched file is a *.bats
# spec, a pytest module (test_*.py / *_test.py), or doc/test/TEST.md,
# verify that each `### test/<path> (N)` heading in TEST.md matches the
# actual test count in that file. On any mismatch, emit a JSON
# systemMessage so Claude sees the warning. Non-blocking — always exit 0.
#
# TEST.md heading format (single source of truth):
#   ### test/unit/setup_spec.bats (166)
#   ### test/integration/upgrade_spec.bats (6)
#   ### .base/test/smoke/script_help.bats (27)   # subtree-shared (refs #156)
#   ### test/unit/widget_test.py (12)            # pytest (refs #198)
# Per-section count is authoritative; some sections summarise by category
# rather than per-test, so a row-count grep does not work. Per-file count
# does. The optional `.base/` prefix lets downstream repos pin counts on
# tests vendored via the `.base/` subtree (otherwise a base subtree pull
# that lands new @test stanzas would drift TEST.md silently).
#
# Counting unit per extension:
#   .bats -> `^@test` stanza count.
#   .py   -> `def test_` function-definition count (top-level + class
#            methods), NOT pytest-collected cases. `@pytest.mark.
#            parametrize` expands one `def test_` into many collected
#            cases, but the guard compares def-counts on both sides, so
#            it stays internally consistent (it tracks drift, not the
#            absolute collected total). Refs #198.
#
# Repo discovery: walk up from the touched file until we find a directory
# containing both `test/` and `doc/test/TEST.md`.

set -uo pipefail

main() {
  local input file_path dir repo_root mismatches
  input="$(cat)"
  file_path="$(printf '%s' "${input}" | jq -r '
    .tool_input.file_path
    // .tool_response.filePath
    // empty
  ' 2>/dev/null)"

  [[ -z "${file_path}" ]] && return 0

  case "${file_path}" in
    *.bats|*/doc/test/TEST.md) ;;
    */test_*.py|*_test.py) ;;   # pytest discovery patterns (refs #198)
    *) return 0 ;;
  esac

  dir="$(dirname "${file_path}")"
  repo_root=""
  while [[ "${dir}" != "/" && "${dir}" != "." ]]; do
    if [[ -d "${dir}/test" && -f "${dir}/doc/test/TEST.md" ]]; then
      repo_root="${dir}"
      break
    fi
    dir="$(dirname "${dir}")"
  done

  [[ -z "${repo_root}" ]] && return 0

  # Per-spec `### <path> (N)` headers live in the per-type catalogs under
  # doc/test/ since the base #695 split (TEST.md is the index now); scan
  # every doc/test/*.md (the glob still includes TEST.md for unsplit repos).

  # Pure bash — avoid gawk-only `match($0, /re/, arr)` 3-arg form which
  # silently mis-runs under mawk / POSIX awk.
  mismatches=""
  while IFS= read -r line; do
    [[ "${line}" =~ ^\#\#\#[[:space:]]((\.base/)?test/[^[:space:]]+\.(bats|py))[[:space:]]\(([0-9]+)\) ]] || continue
    local rel="${BASH_REMATCH[1]}"
    local ext="${BASH_REMATCH[3]}"
    local expected="${BASH_REMATCH[4]}"
    local path="${repo_root}/${rel}"
    if [[ ! -f "${path}" ]]; then
      mismatches+="  ${rel}: listed in doc/test catalog but file missing"$'\n'
      continue
    fi
    local actual
    case "${ext}" in
      bats) actual="$(grep -c '^@test' "${path}" 2>/dev/null || printf '0')" ;;
      py)   actual="$(grep -cE '^[[:space:]]*def test_' "${path}" 2>/dev/null || printf '0')" ;;
    esac
    if (( actual != expected )); then
      mismatches+="  ${rel}: doc/test catalog says ${expected}, actual ${actual}"$'\n'
    fi
  done < <(cat "${repo_root}"/doc/test/*.md 2>/dev/null)
  mismatches="${mismatches%$'\n'}"

  if [[ -n "${mismatches}" ]]; then
    local msg
    msg="$(printf 'TEST.md drift in %s:\n%s' "${repo_root}" "${mismatches}")"
    jq -n --arg m "${msg}" '{
      systemMessage: $m,
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $m
      }
    }'
  fi

  return 0
}

main "$@"
