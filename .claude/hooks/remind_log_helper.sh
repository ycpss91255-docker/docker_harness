#!/usr/bin/env bash
# remind_log_helper.sh -- Claude Code PostToolUse hook.
#
# Fires on Edit / Write / MultiEdit. When the touched file is a
# `.claude/scripts/*.sh` (excluding `lib/`), runs
# check-log-helper-usage.sh against just that file and surfaces any
# bare `printf` / `echo` callsites as a non-blocking systemMessage
# nudge. The intent is to catch new diagnostics before they ship,
# while the CI lint catches everything that slipped through.
#
# Non-blocking. Always exits 0. The CI `.claude/test/ci.sh
# log-helper-check` target is the gate (local wrapper: `just -f
# .claude/test/justfile log-helper-check`); this hook is the reminder.
#
# Refs: ycpss91255-docker/docker_harness#148 (M5).

set -uo pipefail

readonly TMP_DIR="${TMPDIR:-/tmp}"

main() {
  local input file_path
  input="$(cat)"
  file_path="$(printf '%s' "${input}" | jq -r '
    .tool_input.file_path
    // .tool_response.filePath
    // empty
  ' 2>/dev/null)"

  [[ -z "${file_path}" || ! -f "${file_path}" ]] && return 0

  # Only check .claude/scripts/*.sh (one level deep; skip lib/).
  case "${file_path}" in
    */.claude/scripts/*.sh)
      case "${file_path}" in
        */.claude/scripts/lib/*) return 0 ;;
      esac
      ;;
    *) return 0 ;;
  esac

  local scripts_dir
  scripts_dir="$(dirname -- "${file_path}")"

  # Synthetic scope - copy the touched file into a temp scripts dir
  # so the existing lint can scan just it (the lint scans a whole
  # dir; we slice down to single-file scope for the hook).
  local probe_dir
  probe_dir="$(mktemp -d --tmpdir="${TMP_DIR}" remind-log-XXXXXX 2>/dev/null \
    || mktemp -d "${TMP_DIR}/remind-log-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '${probe_dir}'" RETURN EXIT
  cp -- "${file_path}" "${probe_dir}/"

  local lint_script
  lint_script="${scripts_dir}/check-log-helper-usage.sh"
  if [[ ! -x "${lint_script}" ]]; then
    return 0
  fi

  local lint_out
  lint_out="$("${lint_script}" --scripts-dir "${probe_dir}" 2>&1 || true)"

  if ! printf '%s\n' "${lint_out}" | grep -q 'bare \(printf\|echo\)'; then
    return 0
  fi

  local hits
  hits="$(printf '%s\n' "${lint_out}" | grep 'bare \(printf\|echo\)' | head -5)"

  local msg
  # shellcheck disable=SC2016  # backticks are literal markdown code spans, not command substitution
  msg="$(printf 'Bare printf / echo in %s (project rule: lib/log.sh adoption, refs #148):\n%s\n\nMigrate to _log_<level> <service> <body> [attr=val]..., or add `# log-allow:script` (file-wide) / `# log-allow:start..end` (block) markers for data-product output.' \
    "${file_path}" "${hits}")"

  jq -nc --arg msg "${msg}" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $msg
    },
    systemMessage: $msg
  }'
}

main "$@"
