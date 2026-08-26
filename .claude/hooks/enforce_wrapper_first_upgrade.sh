#!/usr/bin/env bash
# enforce_wrapper_first_upgrade.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# DENIES direct invocations that bypass the `just upgrade` wrapper when the
# repo root has a justfile with an `upgrade` recipe.
# Three matching surfaces all skip the init.sh symlink resync + main.yaml
# `@tag` sed that the just wrapper performs (refs issue #36 -- the
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
# $TMPDIR/claude-checkpoint-enforce-wrapper-first-upgrade-<session>-<hash>.md
# and quotes the matching `touch <ack>` command. A second attempt of the
# same command hits is_acked and is allowed through.
#
# Silent (pass-through) when:
#   - command does not match any of the three surfaces above
#   - repo root has no justfile (no wrapper available, raw call is OK)
#   - the justfile has no `upgrade` recipe (rule N/A)
#   - the agent is already going through `just upgrade ...`
#
# Refs: issue #120 (original) + #120 follow-up (this expansion + #123
#       close-comment promise), #117 (checkpoint helper), #36 (incident),
#       #116 Tier 2 (umbrella).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HOOK_DIR}/../scripts/lib/checkpoint.sh"

readonly HOOK_SLUG="enforce-wrapper-first-upgrade"
readonly REASON='Direct invocation skips the init.sh symlink resync + main.yaml @tag sed that the CI-runner upgrade wrapper performs (refs issue #36).'

main() {
  local input cmd cwd work_dir repo_root version_arg ack_path
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

  # Wrapper detection: a root `justfile` carrying an `upgrade` recipe ->
  # `just upgrade`. Every repo in the org has one (the trigger surfaces
  # only happen in `.base` consumers, whose root carries the container-ops
  # justfile). The make->just migration's transitional runners --
  # `justfile.ci` and `Makefile.ci` -- are retired and are NOT wrappers:
  # no repo root ships either any more (refs #280; was #202 / base#573).
  # No wrapper present -> silent (raw call OK, nothing to enforce).
  # just recipes are `upgrade *args:` / `upgrade:`.
  local canonical_base=""
  if [[ -f "${repo_root}/justfile" ]] \
     && grep -qE '^upgrade([[:space:]]|:)' "${repo_root}/justfile" 2>/dev/null; then
    canonical_base="just upgrade"
  else
    return 0
  fi

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

  # Extract optional version arg for the canonical hint (upgrade.sh form
  # only). just recipes take a positional arg (`just upgrade v0.30.0`).
  version_arg=""
  if [[ "${cmd}" =~ (\.base|template)/upgrade\.sh[[:space:]]+(v[0-9][0-9.]*(-[A-Za-z0-9.]+)?) ]]; then
    version_arg=" ${BASH_REMATCH[2]}"
  fi
  local canonical_with_version="${canonical_base}${version_arg}"

  local md_path
  md_path="$(write_checkpoint \
    "${HOOK_SLUG}" \
    "${cmd}" \
    "${REASON}" \
    "${canonical_with_version}" \
    "Canonical wrapper: ${canonical_base}")"

  local deny_msg
  deny_msg="wrapper-first-upgrade gate (issue #36): direct base/template upgrade path is denied.
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
