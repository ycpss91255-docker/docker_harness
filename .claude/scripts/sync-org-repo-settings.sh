#!/usr/bin/env bash
# log-allow:script -- per-repo delta output is the data product; control-flow errors still route through _log_*.
#
# sync-org-repo-settings.sh -- Sync GitHub repo settings across base-aligned
# repos in the ycpss91255-docker org (base + .base subtree consumers + adjacent
# tooling). One-off projects that don't follow the base workflow (e.g.
# github_runner per ADR-0012, demo-repository) are intentionally out of scope.
#
# Idempotent. Each PUT/PATCH only fires when current state != target.
# Supports --dry-run to preview deltas and --repo <name> to scope to one repo.
#
# Target state (per repo):
#   Actions fork PR approval: all_external_contributors
#   allow_auto_merge: true
#   delete_branch_on_merge: true
#   allow_update_branch: true
#   allow_squash_merge: true
#   allow_rebase_merge: true
#   allow_merge_commit: false   (so the merge button UI default is squash)
#
# Branch protection on default branch (main):
#   required_status_checks.strict = true, contexts = per-repo (see required_check_for)
#   enforce_admins = true
#   required_pull_request_reviews.required_approving_review_count = 0
#   allow_force_pushes / allow_deletions = false
#
# Special cases:
#   .github       -- protection on, but no required_status_checks (doc-only
#                    PRs bypass the `lint` job entirely and would hang the
#                    rollup forever otherwise).
#   private repos -- fork PR approval API and branch protection API are both
#                    blocked on the free tier (422 / 403); only the repo
#                    PATCH settings are synced. Detected via repo.private.
#
# Usage:
#   sync-org-repo-settings.sh [--dry-run] [--repo <name>] [--owner <owner>]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh disable=SC1091
source "${SCRIPT_DIR}/lib/log.sh"

SERVICE="sync-org-repo-settings"
OWNER="ycpss91255-docker"
DRY_RUN=0
SCOPE_REPO=""

# Base-aligned repos only -- consume `.base/` subtree, share the base CI / setup
# conventions, or are adjacent tooling (multi_run, docker_harness, template,
# .github). Add a repo here only after confirming it follows the base workflow.
# Out-of-scope intentionally: github_runner (self-hosted runner provisioning,
# ADR-0012), demo-repository (deleted upstream).
ALL_REPOS=(
  jetson_sdk_manager isaac docker_harness base omniverse_web_viewer ros1_bridge
  template ros2_distro ros_distro sam_manager seggpt urg_node_noetic
  urg_node_humble sick_noetic sick_humble realsense_ros1 realsense_ros2
  gemini_cli codex_cli claude_code ai_agent .github multi_run
)

required_check_for() {
  case "$1" in
    base)                    echo "ci-rollup" ;;
    docker_harness)          echo "bats + shellcheck + hadolint" ;;
    multi_run|template)      echo "test" ;;
    ros_distro|ros2_distro)  echo "ci-passed" ;;
    ros1_bridge)             echo "ci-summary" ;;
    sam_manager)             echo "build" ;;
    .github)                 echo "" ;;
    *)                       echo "call-docker-build / docker-build" ;;
  esac
}

usage() {
  sed -n '3,/^$/{s/^# \{0,1\}//;p;}' "$0"
  exit "${1:-0}"
}

is_private() {
  local repo="$1" v
  v=$(gh api "repos/$OWNER/$repo" --jq '.private' 2>/dev/null) || return 1
  [[ "$v" == "true" ]]
}

# delta_line prints the dry-run / apply marker followed by the delta description.
# Data-product output (covered by # log-allow:script at top).
delta_line() {
  local repo="$1"; shift
  if [[ $DRY_RUN -eq 1 ]]; then printf '[dry-run] %s: %s\n' "$repo" "$*"
  else                          printf '[apply]   %s: %s\n' "$repo" "$*"
  fi
}

sync_fork_pr_approval() {
  local repo="$1" current target="all_external_contributors"
  if is_private "$repo"; then
    [[ $DRY_RUN -eq 1 ]] && delta_line "$repo" "skip fork_pr_approval (private repo)"
    return 0
  fi
  current=$(gh api "repos/$OWNER/$repo/actions/permissions/fork-pr-contributor-approval" \
            --jq '.approval_policy' 2>/dev/null) || current="?"
  if [[ "$current" == "$target" ]]; then
    return 0
  fi
  delta_line "$repo" "fork_pr_approval $current -> $target"
  if [[ $DRY_RUN -eq 0 ]]; then
    if ! gh api -X PUT "repos/$OWNER/$repo/actions/permissions/fork-pr-contributor-approval" \
         -F approval_policy="$target" >/dev/null 2>&1; then
      _log_err "$SERVICE" api_error repo="$repo" endpoint=fork-pr-contributor-approval
      return 1
    fi
  fi
}

sync_repo_settings() {
  local repo="$1" json changes=() c
  if ! json=$(gh api "repos/$OWNER/$repo" 2>/dev/null); then
    _log_err "$SERVICE" api_error repo="$repo" endpoint=repos
    return 1
  fi
  [[ $(echo "$json" | jq -r '.allow_auto_merge')       != "true"  ]] && changes+=("allow_auto_merge=true")
  [[ $(echo "$json" | jq -r '.delete_branch_on_merge') != "true"  ]] && changes+=("delete_branch_on_merge=true")
  [[ $(echo "$json" | jq -r '.allow_update_branch')    != "true"  ]] && changes+=("allow_update_branch=true")
  [[ $(echo "$json" | jq -r '.allow_squash_merge')     != "true"  ]] && changes+=("allow_squash_merge=true")
  [[ $(echo "$json" | jq -r '.allow_rebase_merge')     != "true"  ]] && changes+=("allow_rebase_merge=true")
  [[ $(echo "$json" | jq -r '.allow_merge_commit')     != "false" ]] && changes+=("allow_merge_commit=false")
  if [[ ${#changes[@]} -eq 0 ]]; then
    return 0
  fi
  delta_line "$repo" "repo settings -> ${changes[*]}"
  if [[ $DRY_RUN -eq 0 ]]; then
    local args=()
    for c in "${changes[@]}"; do args+=("-F" "$c"); done
    if ! gh api -X PATCH "repos/$OWNER/$repo" "${args[@]}" >/dev/null 2>&1; then
      _log_err "$SERVICE" api_error repo="$repo" endpoint=repos action=PATCH
      return 1
    fi
  fi
}

sync_branch_protection() {
  local repo="$1" target_check current_state
  if is_private "$repo"; then
    [[ $DRY_RUN -eq 1 ]] && delta_line "$repo" "skip branch protection (private free tier)"
    return 0
  fi
  target_check=$(required_check_for "$repo")
  current_state=$(gh api "repos/$OWNER/$repo/branches/main/protection" 2>/dev/null) || current_state=""

  local current_contexts="<no-protection>"
  local current_strict="?" current_admin="?" current_review="?"
  local current_force="?" current_delete="?"
  if [[ -n "$current_state" ]] && [[ "$current_state" != *'"message"'* ]]; then
    current_contexts=$(echo "$current_state" | jq -r '(.required_status_checks.contexts // []) | join(",")')
    [[ -z "$current_contexts" ]] && current_contexts="<empty>"
    current_strict=$(echo "$current_state" | jq -r '.required_status_checks.strict // false')
    current_admin=$(echo  "$current_state" | jq -r '.enforce_admins.enabled // false')
    current_review=$(echo "$current_state" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0')
    current_force=$(echo  "$current_state" | jq -r '.allow_force_pushes.enabled // false')
    current_delete=$(echo "$current_state" | jq -r '.allow_deletions.enabled // false')
  fi

  local target_contexts
  if [[ -n "$target_check" ]]; then target_contexts="$target_check"
  else                              target_contexts="<empty>"
  fi

  local need=0
  [[ "$current_contexts" != "$target_contexts" ]] && need=1
  [[ "$current_strict"   != "true"             ]] && need=1
  [[ "$current_admin"    != "true"             ]] && need=1
  [[ "$current_review"   != "0"                ]] && need=1
  [[ "$current_force"    != "false"            ]] && need=1
  [[ "$current_delete"   != "false"            ]] && need=1
  if [[ $need -eq 0 ]]; then
    return 0
  fi

  delta_line "$repo" "branch protection -> checks=[$target_contexts] strict=true review=0 admin=true force=false del=false"
  if [[ $DRY_RUN -eq 0 ]]; then
    local body contexts_json
    if [[ -n "$target_check" ]]; then
      contexts_json=$(jq -nc --arg c "$target_check" '[$c]')
    else
      contexts_json='[]'
    fi
    body=$(jq -nc --argjson contexts "$contexts_json" '{
      required_status_checks: {strict: true, contexts: $contexts},
      enforce_admins: true,
      required_pull_request_reviews: {
        dismiss_stale_reviews: false,
        require_code_owner_reviews: false,
        required_approving_review_count: 0
      },
      restrictions: null,
      allow_force_pushes: false,
      allow_deletions: false
    }')
    if ! echo "$body" | gh api -X PUT "repos/$OWNER/$repo/branches/main/protection" --input - >/dev/null 2>&1; then
      _log_err "$SERVICE" api_error repo="$repo" endpoint=branches-main-protection action=PUT
      return 1
    fi
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --repo)    SCOPE_REPO="$2"; shift 2 ;;
      --owner)   OWNER="$2"; shift 2 ;;
      -h|--help) usage 0 ;;
      *)         _log_fatal "$SERVICE" unrecognised_arg arg="$1"; usage 2 ;;
    esac
  done

  local REPOS
  if [[ -n "$SCOPE_REPO" ]]; then
    REPOS=("$SCOPE_REPO")
  else
    REPOS=("${ALL_REPOS[@]}")
  fi

  _log_info "$SERVICE" summary phase=start dry_run="$DRY_RUN" count="${#REPOS[@]}"
  local any_diff=0 failed=0 repo out rc
  for repo in "${REPOS[@]}"; do
    out=$(sync_fork_pr_approval "$repo"; sync_repo_settings "$repo"; sync_branch_protection "$repo")
    rc=$?
    if [[ -n "$out" ]]; then
      printf -- '--- %s ---\n%s\n' "$repo" "$out"
      any_diff=1
    fi
    [[ $rc -ne 0 ]] && failed=1
  done

  if [[ $any_diff -eq 0 ]]; then
    _log_info "$SERVICE" summary phase=end result=already-at-target count="${#REPOS[@]}"
  else
    _log_info "$SERVICE" summary phase=end result=processed count="${#REPOS[@]}"
  fi

  return "$failed"
}

# Allow sourcing for unit tests without auto-running main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
