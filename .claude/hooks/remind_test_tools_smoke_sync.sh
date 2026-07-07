#!/usr/bin/env bash
# remind_test_tools_smoke_sync.sh — Claude Code PostToolUse hook
#
# Fires on Edit / Write / MultiEdit when the touched file is
# Dockerfile.test-tools. Prints a side-by-side reminder of:
#   - alpine packages installed in the FINAL stage of the Dockerfile
#   - tools verified by the corresponding release-test-tools.yaml smoke step
#
# Goal: catch the "added a new alpine package but forgot the matching
# `--version` / `--help` smoke check" pattern before commit, without
# enforcing a strict 1:1 mapping (some packages — ca-certificates,
# coreutils — have no single binary to probe). Non-blocking — exit 0.
#
# Trigger paths (relative match):
#   */dockerfile/Dockerfile.test-tools — main project layout
#
# Sibling release-test-tools.yaml is resolved by replacing the
# `dockerfile/Dockerfile.test-tools` suffix with
# `.github/workflows/release-test-tools.yaml`. If that sibling does not
# exist (atypical layout), the hook stays silent.

set -uo pipefail

main() {
  local input file_path
  input="$(cat)"
  file_path="$(printf '%s' "${input}" | jq -r '
    .tool_input.file_path
    // .tool_response.filePath
    // empty
  ' 2>/dev/null)"

  [[ -z "${file_path}" || ! -f "${file_path}" ]] && return 0

  case "${file_path}" in
    */dockerfile/Dockerfile.test-tools) : ;;
    *) return 0 ;;
  esac

  local root yaml_path
  root="${file_path%/dockerfile/Dockerfile.test-tools}"
  yaml_path="${root}/.github/workflows/release-test-tools.yaml"

  [[ ! -f "${yaml_path}" ]] && return 0

  # Final-stage `apk add --no-cache <pkgs>`. The final stage is the LAST
  # `FROM ...` block without `AS <name>`. We track in_final via awk and
  # collect package names from any `apk add --no-cache` line in that
  # block, stripping line-continuation backslashes.
  local final_stage_pkgs
  final_stage_pkgs="$(awk '
    /^FROM .* [Aa][Ss] / { in_final = 0; next }
    /^FROM / { in_final = 1; next }
    in_final && /apk add --no-cache/ {
      sub(/^.*apk add --no-cache[ \t]+/, "")
      sub(/[ \t]*&&.*$/, "")
      sub(/\\$/, "")
      gsub(/[ \t]+/, " ")
      sub(/^[ \t]+/, "")
      sub(/[ \t]+$/, "")
      print
    }
  ' "${file_path}" | tr '\n' ' ' | tr -s ' ' | sed 's/^ //;s/ $//')"

  # Smoke step `docker run --rm "${image}" <cmd>` lines, captured between
  # the `Smoke test pushed image` step name and the next step boundary.
  local smoke_cmds
  smoke_cmds="$(awk '
    /name: Smoke test pushed image/ { in_step = 1; next }
    in_step && /^[ \t]*- name:/ { in_step = 0 }
    in_step && /docker run --rm.*\$\{image\}/ {
      line = $0
      sub(/^.*docker run --rm[^ ]*[ \t]+"\$\{image\}"[ \t]+/, "", line)
      sub(/[ \t]*(>|2>|#).*$/, "", line)
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (length(line) > 0) print line
    }
  ' "${yaml_path}" | paste -sd ',' - | sed 's/,/, /g')"

  [[ -z "${final_stage_pkgs}" ]] && return 0

  local msg
  msg="$(printf 'test-tools image change reminder:\n  Dockerfile.test-tools final-stage apk add packages: %s\n  release-test-tools.yaml smoke step verified commands: %s\nCross-check that every user-facing package has a matching --version / --help smoke check (e.g. git-subtree -> git subtree --help; parallel -> parallel --version). If one is missing, add it to the smoke step; packages without a standalone command such as ca-certificates / coreutils can be ignored.' \
    "${final_stage_pkgs}" "${smoke_cmds:-(none)}")"

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
