#!/usr/bin/env bash
# check_tag_version_consistency.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. When the command is `git tag` (annotated or
# lightweight) or `git push <remote> <tag>` for a `vX.Y.Z[-rcN]` tag, and the
# repo root has a `.version` file, BLOCKS the command if `.version` content
# does not match the tag name being created/pushed.
#
# Why: CLAUDE.md「Release 流程」(release process) requires the release
# commit to bump `.version` in sync. In the template v0.18.0 / v0.18.1
# case, an ad-hoc tag was pushed directly, skipping /release, which left
# `.version` at v0.17.0 and made `make upgrade-check` forever report a
# false "upgrade available". Issue #36 asked for this safety net at the
# hook layer, so we no longer rely on the agent remembering to run /release.
#
# Detection:
#   1. Match `git tag -a <tag>` / `git tag <tag>` (lightweight)
#      and `git push <remote> <tag>` / `git push <remote> refs/tags/<tag>`.
#   2. Resolve work dir from `git -C <dir>` / `cd <dir> &&` / cwd.
#   3. `git rev-parse --show-toplevel` to find repo root.
#   4. Skip if no `.version` at repo root (rule N/A — this is a downstream
#      consumer with `.base/.version`, docker_harness itself, etc.).
#   5. Compare `.version` content vs the tag name; on mismatch → deny.
#
# Out of scope (silent):
#   - `git tag -d <tag>` (delete) / `git push <remote> :<tag>` (delete)
#   - `git push --tags` (bulk; rare and intentional)
#   - `git tag` with no args (list)
#   - Tags not matching `vX.Y.Z[-rcN]`
#   - Repos without root `.version` (downstream `.base/.version` is the
#     CONSUMED template version, not the repo's own version)

set -uo pipefail

main() {
  local input cmd cwd work_dir repo_root version_file recorded tag msg
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  cwd="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
  [[ -z "${cwd}" ]] && cwd="${PWD}"

  [[ -z "${cmd}" ]] && return 0

  # Skip deletes — out of scope per issue #36.
  [[ "${cmd}" == *"git tag -d"* || "${cmd}" == *"git tag --delete"* ]] && return 0
  [[ "${cmd}" =~ git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*push[[:space:]]+[^[:space:]]+[[:space:]]+:v[0-9] ]] && return 0

  # Skip listing.
  [[ "${cmd}" =~ git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*tag[[:space:]]+(-l|--list)([[:space:]]|$) ]] && return 0

  tag=""
  # `git tag -a vX.Y.Z` / `git tag vX.Y.Z` (lightweight). Allows global flags
  # like `-C <dir>` between `git` and `tag`. Match FIRST positional vX tag.
  if [[ "${cmd}" =~ git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*tag([[:space:]]+(-a|-s|-u|-f|--force|-m[[:space:]]*[^[:space:]]+|--message=[^[:space:]]+))*[[:space:]]+(v[0-9][0-9.]*(-[A-Za-z0-9.]+)?)([[:space:]]|$) ]]; then
    tag="${BASH_REMATCH[4]}"
  # `git push <remote> vX.Y.Z` or `git push <remote> refs/tags/vX.Y.Z`.
  elif [[ "${cmd}" =~ git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*push[[:space:]]+[^[:space:]]+[[:space:]]+(refs/tags/)?(v[0-9][0-9.]*(-[A-Za-z0-9.]+)?)([[:space:]]|$) ]]; then
    tag="${BASH_REMATCH[3]}"
  fi

  [[ -z "${tag}" ]] && return 0

  # Resolve work dir.
  work_dir=""
  if [[ "${cmd}" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
    work_dir="${BASH_REMATCH[1]}"
  elif [[ "${cmd}" =~ cd[[:space:]]+([^[:space:]\&\;]+)[[:space:]]*\&\& ]]; then
    work_dir="${BASH_REMATCH[1]}"
  fi
  [[ -z "${work_dir}" ]] && work_dir="${cwd}"
  [[ "${work_dir}" != /* ]] && work_dir="${cwd}/${work_dir}"

  repo_root="$(git -C "${work_dir}" rev-parse --show-toplevel 2>/dev/null)"
  [[ -z "${repo_root}" ]] && return 0

  version_file="${repo_root}/.version"
  [[ -f "${version_file}" ]] || return 0

  recorded="$(tr -d '[:space:]' < "${version_file}" 2>/dev/null)"
  [[ -z "${recorded}" ]] && return 0
  [[ "${recorded}" == "${tag}" ]] && return 0

  msg="$(printf 'tag-version mismatch in %s:\n  attempting %s for %s, but .version says %s.\n  Run /release (or bump .version + CHANGELOG promotion in a chore commit) before tagging.\n  See CLAUDE.md「Release 流程」.' \
    "${repo_root}" "${tag}" "${cmd}" "${recorded}")"

  jq -n --arg m "${msg}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $m
    }
  }'

  return 0
}

main "$@"
