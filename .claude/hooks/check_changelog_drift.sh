#!/usr/bin/env bash
# check_changelog_drift.sh — Claude Code PreToolUse hook (matcher: Bash)
#
# Fires before any Bash command. When the command is `git commit`, check
# whether non-doc files are staged without a corresponding update to the
# repo's live changelog. On drift, emit a JSON systemMessage.
# Non-blocking — exit 0.
#
# Why: CLAUDE.md「變更完成 checklist」(change-completion checklist) item 1
# and「文件對齊原則」(doc-alignment principle) require that any user-visible
# behavior change add an entry to CHANGELOG.md `[Unreleased]`. Commonly
# missed in the past — a feature commit ships without a CHANGELOG entry and
# only gets backfilled at release; dependabot bot PRs also never touch
# CHANGELOG on their own.
#
# WHICH file: derived via scripts/lib/changelog-path.sh, never named. After
# `ycpss91255-docker/base`#926 split the changelog per `0.Y` series,
# `doc/changelog/CHANGELOG.md` is a GENERATED index and base's
# `changelog-layout` lint refuses a release section in it — so this hook was
# warning that the commit was missing the very file it must not hand-edit,
# on every code commit, while the commit correctly edited the series file. A
# warning that is always wrong is one people learn to scroll past, and it is
# the same warning that fires when someone genuinely forgot an entry.
#
# Detection:
#   1. Resolve work dir from command (`git -C <dir>` / `cd <dir> &&` / cwd).
#   2. `git rev-parse --show-toplevel` to find repo root.
#   3. Skip when the live changelog cannot be derived (rule N/A) — an
#      advisory hook that cannot tell which file is live has nothing useful
#      to say, and guessing is what caused the noise in the first place.
#   4. Diff staged: if any non-doc file staged AND the live changelog not
#      staged AND not `--amend`/`--allow-empty` → warn.
#
# Non-doc = anything outside `doc/`, not `*.md`, not `.gitignore`/`LICENSE*`.
# Conservative — better to over-nag (non-blocking) than miss real drift.

set -uo pipefail

HOOK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly HOOK_DIR
# shellcheck source=../scripts/lib/changelog-path.sh disable=SC1091
source "${HOOK_DIR}/../scripts/lib/changelog-path.sh"

main() {
  local input cmd cwd work_dir repo_root changelog_rel staged has_code has_changelog msg
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  cwd="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
  [[ -z "${cwd}" ]] && cwd="${PWD}"

  [[ -z "${cmd}" ]] && return 0

  # Trigger only on `git commit` (not status/log/show/etc.); exclude --amend.
  [[ "${cmd}" =~ git[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*commit([[:space:]]|$) ]] || return 0
  [[ "${cmd}" == *"--amend"* ]] && return 0
  [[ "${cmd}" == *"--allow-empty"* ]] && return 0

  # Resolve work dir: prefer `git -C <dir>`, then `cd <dir> &&`, else cwd.
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

  changelog_rel="$(changelog_live_rel "${repo_root}")" || return 0

  staged="$(git -C "${repo_root}" diff --cached --name-only 2>/dev/null)"
  [[ -z "${staged}" ]] && return 0

  has_code=0
  has_changelog=0
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    case "${f}" in
      "${changelog_rel}") has_changelog=1 ;;
      doc/*|*.md|.gitignore|LICENSE*|*.lock|.env*) ;;
      *) has_code=1 ;;
    esac
  done <<< "${staged}"

  (( has_code == 1 && has_changelog == 0 )) || return 0

  msg="$(printf 'CHANGELOG drift in %s:\n  staged code/config files but %s not in the commit.\n  CLAUDE.md「文件對齊原則」(doc-alignment principle): a user-visible change must add an entry to the [Unreleased] section.\n  Staged files:\n%s' \
    "${repo_root}" "${changelog_rel}" "$(printf '%s' "${staged}" | sed 's/^/    /')")"

  jq -n --arg m "${msg}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $m
    }
  }'

  return 0
}

main "$@"
