#!/usr/bin/env bash
# check_no_stale_template_refs.sh -- Claude Code PostToolUse hook
#
# Fires on Edit / Write / MultiEdit. When the touched file lives under
# .base/ (any subdir) and is a shell script / Makefile / Dockerfile,
# scans for stale `template/<path>` references left over from the
# v0.25.0 subtree rename (template/ -> .base/, refs base#263). Emits
# a non-blocking systemMessage on hits so the developer catches the
# drift at Edit time, before it ships to main.
#
# Why: base#282 went unnoticed because `.base/script/docker/*.sh` was
# moved physically but kept internal `template/script/docker/_lib.sh`
# refs. CI uses Makefile.ci paths and did not exercise the wrapper
# symlinks; fresh-clone `./build.sh` failed silently. A hook firing at
# Edit time catches this in flow instead of 20 minutes later.
#
# Patterns flagged:
#   template/script/        -- old wrapper / ci script lib
#   template/init.sh        -- old subtree init
#   template/upgrade.sh     -- old subtree upgrade
#   template/_lib.sh        -- old shared lib
#   template/setup.conf     -- old config root
#   template/dockerfile/    -- old shared dockerfiles
#   template/test/          -- old shared tests
#   template/config/        -- old shared shell config
#   template/Makefile       -- old top-level Makefile
#
# Skips:
#   - file not under .base/
#   - file not *.sh / Makefile* / Dockerfile* / *.mk
#   - hook self (this file documents the pattern in comments)
#   - hook test fixtures (must contain the pattern to assert detection)
#   - .md files (doc / changelog often discusses the rename)

set -uo pipefail

main() {
  local input file_path hits msg
  input="$(cat)"
  file_path="$(printf '%s' "${input}" | jq -r '
    .tool_input.file_path
    // .tool_response.filePath
    // empty
  ' 2>/dev/null)"

  [[ -z "${file_path}" || ! -f "${file_path}" ]] && return 0

  case "${file_path}" in
    */.git/*|*/node_modules/*) return 0 ;;
    */check_no_stale_template_refs.sh) return 0 ;;
    */.claude/test/bats/*) return 0 ;;
    *.md) return 0 ;;
  esac

  case "${file_path}" in
    */.base/*) ;;
    *) return 0 ;;
  esac

  case "${file_path}" in
    *.sh|*.bash|*.mk) ;;
    */Makefile|*/Makefile.*) ;;
    */Dockerfile|*/Dockerfile.*) ;;
    *) return 0 ;;
  esac

  if file --mime "${file_path}" 2>/dev/null | grep -qE 'charset=binary'; then
    return 0
  fi

  hits="$(grep -nE 'template/(script|init\.sh|upgrade\.sh|_lib|setup\.conf|dockerfile/|test/|config/|Makefile)' "${file_path}" 2>/dev/null \
    | head -5 \
    | awk -F: '{
        line=$1; $1=""; sub(/^ /, "");
        snippet=$0; if (length(snippet) > 80) snippet=substr(snippet, 1, 80);
        printf "  line %s: %s\n", line, snippet
      }')"

  [[ -z "${hits}" ]] && return 0

  msg="$(printf 'Stale template/ reference in %s (renamed to .base/ in base v0.25.0, refs #263):\n%s\n  Replace template/ -> .base/ to avoid fresh-clone breakage (refs base#282).' \
    "${file_path}" "${hits}")"

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
