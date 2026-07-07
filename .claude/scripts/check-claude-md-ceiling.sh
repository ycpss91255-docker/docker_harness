#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

# check-claude-md-ceiling.sh
#
# Audit a markdown file (default: CLAUDE.md) against hard ceilings on
# total line count and on `^##` (any-depth) section count. Designed for
# CI lint -- exits non-zero on ceiling violation so the build fails.
#
# Ceilings are env-overridable so the spec can drive small numbers
# through fixture content without touching real CLAUDE.md.
#
# Wired into `just -f .claude/test/justfile check` (CI runs the same
# `.claude/test/ci.sh check` driver) via the `ceiling-check` target
# after #127 PR-B lands. PR-A ships this script alone; the wire-in is
# deferred so PR-A is not self-failing against the pre-slim 965-line
# CLAUDE.md.

set -euo pipefail

readonly DEFAULT_MAX_LINES=240
readonly DEFAULT_MAX_SECTIONS=20

usage() {
  cat >&2 <<EOF
Usage: $0 [path/to/CLAUDE.md]

Audit a markdown file against the CLAUDE.md slim ceilings (refs #127).
If no path is given, defaults to \`\${CLAUDE_PROJECT_DIR:-cwd}/CLAUDE.md\`.

Ceilings (env-overridable):
  MAX_LINES     (default ${DEFAULT_MAX_LINES})  hard upper bound on \`wc -l\`
  MAX_SECTIONS  (default ${DEFAULT_MAX_SECTIONS})   hard upper bound on \`grep -c '^##'\`
                                  (matches any \`##\` / \`###\` / \`####\`)

Exit codes:
  0  Both ceilings respected
  1  At least one ceiling exceeded
  2  Usage / file-not-found error
EOF
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
  esac

  local file="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}/CLAUDE.md}"

  if [[ ! -f "${file}" ]]; then
    echo "error: file not found at: ${file}" >&2
    exit 2
  fi

  local max_lines="${MAX_LINES:-${DEFAULT_MAX_LINES}}"
  local max_sections="${MAX_SECTIONS:-${DEFAULT_MAX_SECTIONS}}"

  local lines
  lines=$(wc -l < "${file}")
  local sections
  # `|| true` because `grep -c` exits 1 when no match; we want the
  # count (0), not a failure.
  sections=$(grep -c '^##' "${file}" || true)

  local fail=0
  if (( lines > max_lines )); then
    echo "FAIL: ${file} has ${lines} lines (max ${max_lines})" >&2
    fail=1
  fi
  if (( sections > max_sections )); then
    echo "FAIL: ${file} has ${sections} \`^##\` sections (max ${max_sections})" >&2
    fail=1
  fi

  if (( fail == 0 )); then
    echo "${file}: ${lines} lines / ${sections} sections (within ${max_lines}/${max_sections})"
  fi

  exit "${fail}"
}

main "$@"
