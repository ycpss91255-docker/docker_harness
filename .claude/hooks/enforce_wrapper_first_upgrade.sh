#!/usr/bin/env bash
# enforce_make_first_upgrade.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# DENIES direct invocations that bypass the `make -f Makefile.ci upgrade`
# wrapper when the repo root has a `Makefile.ci` with an `upgrade:` target.
# Three matching surfaces all skip the init.sh symlink resync + main.yaml
# `@tag` sed that the make wrapper performs (refs issue #36 -- the
# template v0.18.x incident where the missed sed left downstream
# `make upgrade-check` permanently reporting "upgrade available"):
#
#   1. `./.base/upgrade.sh ...` and absolute / relative variants
#   2. `./template/upgrade.sh ...` (legacy local folder name; the GitHub
#      repo was renamed `template -> base`, but some checkouts retain
#      the old folder name)
#   3. `git subtree pull --prefix=.base ...` or `--prefix=template ...`
#      (the raw subtree pull skips the same wrapper steps)
#
# Lift mechanism: the `/tmp` checkpoint protocol (ADR-00000002 / #117).
# On deny, write_checkpoint renders a five-section markdown to
# $TMPDIR/claude-checkpoint-enforce-make-first-upgrade-<session>-<hash>.md
# and quotes the matching `touch <ack>` command. A second attempt of the
# same command hits is_acked and is allowed through.
#
# Silent (pass-through) when:
#   - command does not match any of the three surfaces above
#   - cwd has no Makefile.ci (no make wrapper available, raw call is OK)
#   - Makefile.ci has no `upgrade:` target (rule N/A)
#   - the agent is already going through `make -f Makefile.ci upgrade ...`
#
# Refs: issue #120 (original) + #120 follow-up (this expansion + #123
#       close-comment promise), #117 (checkpoint helper), #36 (incident),
#       #116 Tier 2 (umbrella).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HOOK_DIR}/../scripts/lib/checkpoint.sh"

readonly HOOK_SLUG="enforce-make-first-upgrade"
readonly CANONICAL='make -f Makefile.ci upgrade VERSION=vX.Y.Z'
readonly REASON='Direct invocation skips the init.sh symlink resync + main.yaml @tag sed that the make wrapper performs (refs issue #36).'

main() {
  local input cmd cwd work_dir repo_root makefile version_arg ack_path
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  cwd="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
  [[ -z "${cwd}" ]] && cwd="${PWD}"

  [[ -z "${cmd}" ]] && return 0

  # Trigger detection -- three surfaces, all routed to `make upgrade`.
  local matched=0
  # Surface 1+2: <prefix>/.base/upgrade.sh or <prefix>/template/upgrade.sh
  if [[ "${cmd}" =~ (^|[[:space:]\;\&\|])(\./)?(.*/)?(\.base|template)/upgrade\.sh([[:space:]]|$) ]]; then
    matched=1
  # Surface 3: git subtree pull --prefix=.base or --prefix=template
  elif [[ "${cmd}" =~ git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?subtree[[:space:]]+pull[[:space:]] ]] \
       && [[ "${cmd}" =~ --prefix=(\.base|template)([[:space:]]|$) ]]; then
    matched=1
  fi
  (( matched )) || return 0

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
  [[ -z "${repo_root}" ]] && repo_root="${work_dir}"

  makefile="${repo_root}/Makefile.ci"
  [[ -f "${makefile}" ]] || return 0
  grep -qE '^upgrade:' "${makefile}" 2>/dev/null || return 0

  # Short-circuit if the user has already acked this exact command.
  if ack_path="$(is_acked "${HOOK_SLUG}" "${cmd}")"; then
    jq -n --arg p "${ack_path}" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        permissionDecisionReason: ("user previously acked via " + $p)
      }
    }'
    return 0
  fi

  # Extract optional version arg for the canonical hint (upgrade.sh form only).
  version_arg=""
  if [[ "${cmd}" =~ (\.base|template)/upgrade\.sh[[:space:]]+(v[0-9][0-9.]*(-[A-Za-z0-9.]+)?) ]]; then
    version_arg=" VERSION=${BASH_REMATCH[2]}"
  fi
  local canonical_with_version="make -f Makefile.ci upgrade${version_arg}"

  local md_path
  md_path="$(write_checkpoint \
    "${HOOK_SLUG}" \
    "${cmd}" \
    "${REASON}" \
    "${canonical_with_version}" \
    "Canonical wrapper: ${CANONICAL}")"

  local deny_msg
  deny_msg="make-first-upgrade gate (issue #36): direct base/template upgrade path is denied.
Use the canonical wrapper:
  ${canonical_with_version}
Why: ${REASON}
Checkpoint written to:
  ${md_path}
If you really want to run the original command, touch the matching ack
file (see section 4 of the checkpoint), then re-issue the same command.
The companion auto_allow_touch_ack.sh hook allows the ack touch."

  jq -n --arg m "${deny_msg}" '{
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
