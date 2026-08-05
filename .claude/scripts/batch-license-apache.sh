#!/bin/bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

# One-shot batch fanout: fresh-add Apache 2.0 LICENSE + CI/License
# badges to the 13 active downstream container repos under
# ycpss91255-docker. Tracks org-wide license alignment recorded in
# 17 sister issues (refs docker_harness#52, template#246).
#
# What it does per repo:
#   1. git worktree add from origin/main (HTTPS fetch + reset to
#      avoid SSH-blocked sandbox; main checkout untouched).
#   2. Write LICENSE = "Copyright 2026 ycpss91255\n\n" + verbatim
#      Apache 2.0 text from /tmp/apache-2.0.txt (must be pre-fetched
#      via `gh api /licenses/apache-2.0 --jq .body`).
#   3. Insert two badges (CI for main.yaml + License Apache--2.0
#      shield) right after the H1 in README.md and the three
#      doc/README.<lang>.md translations. Translated READMEs link
#      LICENSE via ../LICENSE; root README via ./LICENSE.
#   4. Add `[Unreleased] / Added` CHANGELOG entry referencing the
#      repo's per-repo license issue.
#   5. Commit, push via HTTPS, open PR closing the issue.
#
# Usage:
#   .claude/scripts/batch-license-apache.sh             # all 13
#   .claude/scripts/batch-license-apache.sh ai_agent    # filter
#   .claude/scripts/batch-license-apache.sh --dry-run   # show plan

set -euo pipefail

readonly ORG="ycpss91255-docker"
readonly LICENSE_SOURCE="/tmp/apache-2.0.txt"
readonly BRANCH="chore/license-apache-2"
readonly TITLE="chore: add Apache 2.0 LICENSE + CI/License badges"
readonly WORKSPACE="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
_BLA_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=lib/log.sh disable=SC1091
source "${_BLA_SCRIPT_DIR}/lib/log.sh"

# repo|category|issue
# roster-exempt: one-shot org-wide Apache-2.0 LICENSE add, already executed.
# Each row carries its own per-repo issue number, so this is a run record
# rather than a scope list.
readonly REPOS=(
  "ai_agent|agent|41"
  "claude_code|agent|40"
  "codex_cli|agent|39"
  "gemini_cli|agent|39"
  "ros_distro|env|6"
  "ros2_distro|env|6"
  "ros1_bridge|app|66"
  "urg_node_humble|app|37"
  "urg_node_noetic|app|40"
  "sick_humble|app|41"
  "sick_noetic|app|40"
  "realsense_humble|app|41"
  "realsense_noetic|app|40"
)

usage() {
  cat >&2 <<EOF
Usage: $0 [OPTIONS] [REPO ...]

Open license-migration PR (Apache 2.0 fresh add) on each named repo.
With no args, processes all 13 active downstream container repos.

Options:
  --dry-run    Print the plan, do not mutate.
  -h|--help    Show this help.

Filtered repos must match the basename column in the embedded REPOS
table (no category prefix).
EOF
}

generate_license() {
  local out="$1"
  printf 'Copyright 2026 ycpss91255\n\n' > "${out}"
  cat "${LICENSE_SOURCE}" >> "${out}"
}

insert_badges() {
  # $1 = README path
  # $2 = repo basename
  # $3 = LICENSE relative path from this README (./LICENSE or ../LICENSE)
  local readme="$1"
  local repo="$2"
  local license_path="$3"
  local ci_url="https://github.com/${ORG}/${repo}/actions/workflows/main.yaml"
  local badge_line
  badge_line="[![CI](${ci_url}/badge.svg)](${ci_url}) [![License](https://img.shields.io/badge/License-Apache--2.0-blue?style=flat-square)](${license_path})"

  awk -v badge="${badge_line}" '
    !inserted && /^# / {
      print
      print ""
      print badge
      inserted = 1
      next
    }
    { print }
  ' "${readme}" > "${readme}.tmp"
  mv "${readme}.tmp" "${readme}"
}

add_changelog_entry() {
  # $1 = CHANGELOG path
  # $2 = issue number
  local changelog="$1"
  local issue="$2"

  awk -v issue="${issue}" '
    BEGIN { inserted = 0 }
    !inserted && /^## \[Unreleased\]/ {
      print
      print ""
      print "### Added"
      print "- `LICENSE` (Apache 2.0) and CI / License badges in"
      print "  `README.md` + 3 translated READMEs (#" issue "). Fresh add"
      print "  -- repo previously had no LICENSE and no badges. Aligns with"
      print "  the org-wide Apache 2.0 migration tracked across 17 sister"
      print "  repos."
      inserted = 1
      next
    }
    { print }
  ' "${changelog}" > "${changelog}.tmp"
  mv "${changelog}.tmp" "${changelog}"
}

write_pr_body() {
  # $1 = output path
  # $2 = repo basename
  # $3 = issue number
  local out="$1"
  local repo="$2"
  local issue="$3"
  cat > "${out}" <<EOF
## Why

Closes #${issue}. Org-wide license alignment to Apache 2.0 -- see issue body for full rationale (matches upstream osrf/docker_images, explicit patent grant + retaliation, avoids the GPL viral concern when the template subtree is bundled inside this repo).

This is a fresh add: \`${repo}\` previously had no LICENSE and no README badges.

## What

- **\`LICENSE\`** -- added Apache 2.0 full text from <https://www.apache.org/licenses/LICENSE-2.0.txt> (verbatim, 202 lines), prepended with \`Copyright 2026 ycpss91255\` header per the issue spec.
- **\`README.md\` + \`doc/README.{zh-TW,zh-CN,ja}.md\`** -- inserted two badges immediately after the H1 on a single line:
  - CI badge for \`main.yaml\` workflow
  - License badge linking to the new \`LICENSE\` (\`./LICENSE\` from root, \`../LICENSE\` from translated READMEs)
- **\`doc/changelog/CHANGELOG.md\`** -- \`[Unreleased] / Added\` entry covering the LICENSE + badge fresh add.

No code, Dockerfile, or workflow changes -- pure license + doc.

## Verification

Pure metadata / documentation change. CI runs the standard build and smoke pipeline; LICENSE / README / CHANGELOG changes don't affect any tested behaviour.

Generated by \`.claude/scripts/batch-license-apache.sh\`, opened in lockstep with 12 sister PRs across the active org for the same migration.
EOF
}

process_repo() {
  local entry="$1"
  local dry_run="$2"
  local repo category issue
  IFS='|' read -r repo category issue <<<"${entry}"

  local repo_path="${WORKSPACE}/${category}/${repo}"
  local worktree_path="${WORKSPACE}/worktree/${repo}-${issue}-license"
  local body_file="/tmp/pr-${repo}-license.md"

  _log_info batch-license processing_repo org="${ORG}" repo="${repo}" issue="${issue}" category="${category}"

  if [[ ! -d "${repo_path}" ]]; then
    _log_warn batch-license repo_skipped repo="${repo}" reason=not-present path="${repo_path}"
    return 1
  fi

  if [[ "${dry_run}" == "true" ]]; then
    _log_info batch-license dry_run_cmd repo="${repo}" worktree="${worktree_path}" branch="${BRANCH}" issue="${issue}" action="worktree+LICENSE+README+CHANGELOG+push+PR"
    return 0
  fi

  if [[ -d "${worktree_path}" ]]; then
    _log_warn batch-license worktree_exists repo="${repo}" path="${worktree_path}"
    return 1
  fi

  git -C "${repo_path}" worktree add "${worktree_path}" -b "${BRANCH}" origin/main 2>&1 | tail -3
  git -C "${worktree_path}" fetch "https://github.com/${ORG}/${repo}.git" main 2>&1 | tail -2
  git -C "${worktree_path}" reset --hard FETCH_HEAD 2>&1 | tail -1

  generate_license "${worktree_path}/LICENSE"
  insert_badges "${worktree_path}/README.md" "${repo}" "./LICENSE"

  local lang
  for lang in zh-TW zh-CN ja; do
    local translated="${worktree_path}/doc/README.${lang}.md"
    if [[ -f "${translated}" ]]; then
      insert_badges "${translated}" "${repo}" "../LICENSE"
    fi
  done

  add_changelog_entry "${worktree_path}/doc/changelog/CHANGELOG.md" "${issue}"

  git -C "${worktree_path}" add LICENSE README.md \
    doc/README.zh-TW.md doc/README.zh-CN.md doc/README.ja.md \
    doc/changelog/CHANGELOG.md
  git -C "${worktree_path}" commit -m "${TITLE}

Closes #${issue}"

  git -C "${worktree_path}" push "https://github.com/${ORG}/${repo}.git" \
    "${BRANCH}:${BRANCH}" 2>&1 | tail -3

  write_pr_body "${body_file}" "${repo}" "${issue}"
  gh pr create --repo "${ORG}/${repo}" --base main --head "${BRANCH}" \
    --title "${TITLE}" --body-file "${body_file}"
}

main() {
  local dry_run="false"
  local -a filter=()
  while (( $# > 0 )); do
    case "$1" in
      --dry-run) dry_run="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift; filter+=("$@"); break ;;
      -*) _log_fatal batch-license unrecognised_arg arg="${1}"; usage; exit 2 ;;
      *) filter+=("$1"); shift ;;
    esac
  done

  if [[ ! -f "${LICENSE_SOURCE}" ]]; then
    _log_fatal batch-license license_source_missing path="${LICENSE_SOURCE}" hint="gh api /licenses/apache-2.0 --jq .body > ${LICENSE_SOURCE}"
    exit 1
  fi

  local entry repo
  local -i ok=0 fail=0
  for entry in "${REPOS[@]}"; do
    IFS='|' read -r repo _ _ <<<"${entry}"
    if (( ${#filter[@]} > 0 )); then
      local match="false"
      local f
      for f in "${filter[@]}"; do
        [[ "${f}" == "${repo}" ]] && match="true" && break
      done
      [[ "${match}" == "false" ]] && continue
    fi
    if process_repo "${entry}" "${dry_run}"; then
      (( ok += 1 ))
    else
      (( fail += 1 ))
    fi
  done

  _log_info batch-license summary ok="${ok}" fail="${fail}"
  if (( ${#filter[@]} == 0 )); then
    printf 'After all PRs are open, monitor CI with:\n'
    printf '  .claude/scripts/wait-pr-ci-batch.sh \\\n'
    printf '    ai_agent:N1 claude_code:N2 codex_cli:N3 gemini_cli:N4 \\\n'
    printf '    ros_distro:N5 ros2_distro:N6 ros1_bridge:N7 \\\n'
    printf '    urg_node_humble:N8 urg_node_noetic:N9 sick_humble:N10 \\\n'
    printf '    sick_noetic:N11 realsense_humble:N12 realsense_noetic:N13 \\\n'
    printf '    --check-filter '"'"'.name=="call-docker-build / docker-build"'"'"' \\\n'
    printf '    --check-filter '"'"'ros_distro=.name=="ci-passed"'"'"' \\\n'
    printf '    --check-filter '"'"'ros2_distro=.name=="ci-passed"'"'"' \\\n'
    printf '    --check-filter '"'"'ros1_bridge=.name=="ci-summary"'"'"'\n'
  fi
}

main "$@"
