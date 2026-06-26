#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

# batch-open-archive-rename-issues.sh — open 11 follow-up issues across
# downstream repos parked from docker_harness's active upgrade list.
#
# 7 archive issues (4 agent + 3 ROS app):
#   - agent/ai_agent, claude_code, codex_cli, gemini_cli
#     (no concrete container plan; archive until plan)
#   - app/ros1_bridge, sick_humble, sick_noetic
#     (functionally covered by env/ros_distro + env/ros2_distro)
#
# 4 rename + .base subtree migration issues (sensor repos predating the
# multi-distro env consolidation):
#   - app/urg_node_humble  -> urg_node_ros2
#   - app/urg_node_noetic  -> urg_node_ros
#   - app/realsense_humble -> realsense_ros2
#   - app/realsense_noetic -> realsense_ros
#
# Each issue body is written to ${TMPDIR:-/tmp}/issue-<slug>.md first
# (per enforce_gh_body_file.sh rule 1) then `gh issue create --body-file`
# is invoked. Skips repos that already have an open / closed issue with
# the same title (idempotent re-run safe).
#
# Usage:
#   batch-open-archive-rename-issues.sh [options]
#
# Options:
#   --owner <OWNER>      Default owner (default: ycpss91255-docker)
#   --refs <URL-or-#N>   Cross-ref string appended to each body's "refs"
#                        line (e.g. https://github.com/.../pull/86 or #86)
#   --only <slugs,...>   Limit to listed basenames (e.g. ai_agent,sick_humble,
#                        urg_node_humble)
#   --dry-run            Print planned issues; skip gh invocations
#   -h, --help           Show this help
#
# Behaviour:
#   - For each entry: write body to /tmp, check if title already exists
#     on the target repo, then `gh issue create`. Existing title skips.
#   - On gh failure, prints the error and continues; summary at end shows
#     created / skipped / failed counts. Non-zero exit if any failed.

set -euo pipefail

_BOARI_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=lib/log.sh disable=SC1091
source "${_BOARI_SCRIPT_DIR}/lib/log.sh"

readonly DEFAULT_OWNER='ycpss91255-docker'
readonly TMP_DIR="${TMPDIR:-/tmp}"

# Archive entries: <repo_basename>|<reason_short>
readonly ARCHIVE_REPOS=(
  'ai_agent|no concrete container plan'
  'claude_code|no concrete container plan'
  'codex_cli|no concrete container plan'
  'gemini_cli|no concrete container plan'
  'ros1_bridge|covered by env/ros_distro + env/ros2_distro'
  'sick_humble|covered by env/ros2_distro'
  'sick_noetic|covered by env/ros_distro'
)

# Rename entries: <old_repo>|<new_repo>|<ros_version_label>
# ROS 1 targets use the explicit *_ros1 suffix (org naming convention,
# .github#23 / 2026-06-25): bare *_ros (= implicit ROS 1) is retired.
# realsense_noetic is already renamed to realsense_ros1 (realsense_ros1#52),
# so its entry is historical; kept with the corrected target so a re-run
# advertises the right name. This is a one-time tool (re-run out of scope).
readonly RENAME_REPOS=(
  'urg_node_humble|urg_node_ros2|ROS 2'
  'urg_node_noetic|urg_node_ros1|ROS 1'
  'realsense_humble|realsense_ros2|ROS 2'
  'realsense_noetic|realsense_ros1|ROS 1'
)

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

issue_title_archive() {
  local repo="$1"
  printf 'chore: archive %s (out of docker_harness active list)' "${repo}"
}

issue_title_rename() {
  local old="$1" new="$2"
  printf 'chore: rename %s -> %s (+ .base migration)' "${old}" "${new}"
}

write_archive_body() {
  local repo="$1" reason="$2" refs="$3"
  local body_path="${TMP_DIR}/issue-archive-${repo}.md"
  local refs_section=""
  if [[ -n "${refs}" ]]; then
    refs_section="

refs ${refs}"
  fi

  cat > "${body_path}" <<EOF
## Context

This repo (\`${repo}\`) is no longer in docker_harness's active upgrade
list. The \`DEFAULT_REPOS\` arrays in
\`.claude/scripts/batch-base-upgrade.sh\`,
\`check-template-versions.sh\`, and \`batch-gitignore-add-line.sh\` now
contain only \`env/ros_distro\` and \`env/ros2_distro\`; the rest are
commented out pending follow-up.

## Problem

\`${repo}\` is parked: ${reason}. Keeping it live without an upgrade flow
risks drift between its \`.base/\` subtree and template HEAD, and burns
maintainer attention on CI failures we are not planning to chase.

## Proposal

Archive the GitHub repo (Settings -> General -> Archive this repository).
Move the local checkout to \`<workspace>/archive/${repo}/\` to match the
pattern of existing archived repos (\`archive/ros_noetic\`,
\`archive/osrf_ros2_humble\`, etc.).

## Acceptance

- [ ] GitHub repo marked archived (read-only)
- [ ] Local checkout moved under \`<workspace>/archive/${repo}/\`
- [ ] docker_harness \`CONTEXT.md\` sec 2.1 \`archive/\` block appended
      with the entry (post-#127 the directory tree moved from \`CLAUDE.md\`
      to \`CONTEXT.md\` sec 2.1; post-#130 per-repo lifecycle annotations
      live in \`.claude/scripts/batch-base-upgrade.sh\` \`DEFAULT_REPOS\`
      + this script's follow-up issues, not in the tree listing)

## Out of scope

- Whether to revive the container later. The archived snapshot remains the
  source of truth if needed; un-archiving + adding to \`DEFAULT_REPOS\` is a
  separate decision.${refs_section}
EOF
  printf '%s\n' "${body_path}"
}

write_rename_body() {
  local old="$1" new="$2" ros_ver="$3" refs="$4"
  local body_path="${TMP_DIR}/issue-rename-${old}.md"
  local refs_section=""
  if [[ -n "${refs}" ]]; then
    refs_section="

refs ${refs}"
  fi

  cat > "${body_path}" <<EOF
## Context

\`${old}\` predates the multi-distro env consolidation. Its name ties to a
specific distro (the \`_humble\` / \`_noetic\` suffix), whereas the
pattern established by \`env/ros_distro\` and \`env/ros2_distro\` is one
repo per ROS major version with the distro picked via build matrix.

Concurrently, this repo still uses the legacy \`template/\` subtree
prefix; the rest of the org migrated to \`.base/\` in #263 Phase 6.

## Problem

Two prerequisites block docker_harness from re-adding this repo to its
active \`DEFAULT_REPOS\` arrays:

1. **Subtree prefix migration**: \`template/\` -> \`.base/\`. Mirror the
   one-time fanout precedent in
   \`.claude/scripts/batch-rename-template-to-base.sh\`.
2. **Repo rename**: \`${old}\` -> \`${new}\`. Aligns with the ${ros_ver}
   convention and leaves room for a multi-distro matrix later.

## Proposal

- Step 1: Subtree migration PR (\`git rm template/\` +
  \`git subtree add --prefix=.base ycpss91255-docker/base.git vX.Y.Z\` +
  Dockerfile / \`.github/workflows/main.yaml\` / README path sed).
- Step 2: GitHub repo rename \`${old}\` -> \`${new}\` (Settings ->
  General -> Repository name). Existing clones / forks redirect via the
  GitHub rename alias.
- Step 3: docker_harness PR uncommenting \`app/${old}\` (renamed to
  \`app/${new}\`) in the three \`DEFAULT_REPOS\` arrays plus the CLAUDE.md
  directory-tree update.

## Acceptance

- [ ] \`.base/\` subtree present with \`.base/.version\` matching the
      target template tag
- [ ] No remaining \`template/\` references — \`check_no_stale_template_refs.sh\`
      passes against the new \`.base/\` content
- [ ] GitHub repo renamed to \`${new}\`
- [ ] docker_harness \`DEFAULT_REPOS\` re-includes the repo (under new name)
      via a follow-up PR
- [ ] CI green on the first post-rename run

## Out of scope

- Expanding the build matrix to additional distros (e.g. jazzy for
  ${new}). Track separately once the rename lands.${refs_section}
EOF
  printf '%s\n' "${body_path}"
}

# Returns 0 if a title-exact-match issue (any state) exists on owner/repo.
issue_exists() {
  local owner_repo="$1" title="$2"
  gh issue list -R "${owner_repo}" --state all --limit 100 \
    --json title --jq '.[].title' \
    | grep -Fxq -- "${title}"
}

create_issue() {
  local owner_repo="$1" title="$2" body_path="$3" dry_run="$4"

  if (( dry_run == 0 )); then
    if issue_exists "${owner_repo}" "${title}"; then
      _log_info batch-issues issue_skipped owner_repo="${owner_repo}" title="${title}" reason=already-exists
      return 2
    fi
  fi

  if (( dry_run )); then
    _log_info batch-issues dry_run_cmd owner_repo="${owner_repo}" title="${title}" body_path="${body_path}"
    return 0
  fi

  _log_info batch-issues processing_repo owner_repo="${owner_repo}" title="${title}" action=create
  # --label enhancement: archive + rename issues are all chore(*) titles;
  # chore maps to enhancement per gh-artifact-format SKILL.md Section 6.
  # Required by enforce_gh_body_file.sh rule 9 (#91).
  gh issue create -R "${owner_repo}" \
    --title "${title}" \
    --body-file "${body_path}" \
    --label enhancement
}

in_only_list() {
  local target="$1"
  shift
  if (( $# == 0 )); then
    return 0
  fi
  local s
  for s in "$@"; do
    if [[ "${s}" == "${target}" ]]; then
      return 0
    fi
  done
  return 1
}

main() {
  local owner="${DEFAULT_OWNER}"
  local refs=""
  local only_csv=""
  local dry_run=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --owner) owner="$2"; shift 2 ;;
      --refs) refs="$2"; shift 2 ;;
      --only) only_csv="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) _log_fatal batch-issues unrecognised_arg arg="${1}"; usage; exit 2 ;;
    esac
  done

  local -a only_list=()
  if [[ -n "${only_csv}" ]]; then
    IFS=',' read -r -a only_list <<< "${only_csv}"
  fi

  local created=0 skipped=0 failed=0
  local -a failed_repos=()
  local entry repo reason title body rc
  local old new ros_ver

  for entry in "${ARCHIVE_REPOS[@]}"; do
    repo="${entry%%|*}"
    reason="${entry##*|}"
    if ! in_only_list "${repo}" "${only_list[@]}"; then
      continue
    fi

    title="$(issue_title_archive "${repo}")"
    body="$(write_archive_body "${repo}" "${reason}" "${refs}")"

    set +e
    create_issue "${owner}/${repo}" "${title}" "${body}" "${dry_run}"
    rc=$?
    set -e
    case "${rc}" in
      0) created=$((created + 1)) ;;
      2) skipped=$((skipped + 1)) ;;
      *) failed=$((failed + 1)); failed_repos+=("${repo}") ;;
    esac
  done

  for entry in "${RENAME_REPOS[@]}"; do
    IFS='|' read -r old new ros_ver <<< "${entry}"
    if ! in_only_list "${old}" "${only_list[@]}"; then
      continue
    fi

    title="$(issue_title_rename "${old}" "${new}")"
    body="$(write_rename_body "${old}" "${new}" "${ros_ver}" "${refs}")"

    set +e
    create_issue "${owner}/${old}" "${title}" "${body}" "${dry_run}"
    rc=$?
    set -e
    case "${rc}" in
      0) created=$((created + 1)) ;;
      2) skipped=$((skipped + 1)) ;;
      *) failed=$((failed + 1)); failed_repos+=("${old}") ;;
    esac
  done

  _log_info batch-issues summary created="${created}" skipped="${skipped}" failed="${failed}"
  if (( failed > 0 )); then
    printf '  failed: %s\n' "${failed_repos[@]}"
    exit 1
  fi
}

main "$@"
