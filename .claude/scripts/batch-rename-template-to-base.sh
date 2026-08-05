#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

#
# One-shot fanout for #263 Phase 6: rename downstream subtree prefix
# from `template/` to `.base/` and update every consumer reference.
#
# Each affected downstream repo gets one PR that:
#   1. `git rm -r template/`   (drops the old subtree; markers from
#                                ycpss91255-docker/template no longer
#                                apply after the GitHub rename)
#   2. `git subtree add --prefix=.base \
#         ycpss91255-docker/base.git <version> --squash`
#      (clean re-add against the renamed upstream; produces a fresh
#       `git-subtree-dir: .base` marker so future `git subtree pull
#       --prefix=.base` works without forging history)
#   3. If `<repo>/setup.conf` exists at repo root: move it to
#      `<repo>/config/docker/setup.conf` so the post-#262 override
#      layering resumes working.
#   4. Run `./.base/init.sh` so the subtree-prefix auto-detect path
#      from #263 prep recreates all six symlinks (build / run /
#      exec / stop / Makefile / .hadolint.yaml) pointing through
#      `.base/...`.
#   5. Sed Dockerfile `COPY template/` -> `COPY .base/`.
#   6. Sed `.github/workflows/main.yaml` `uses:` refs to
#      `ycpss91255-docker/base/.github/workflows/...@<version>`.
#   7. Sed 4-language README directory tree references.
#   8. Commit + push branch + open PR.
#
# Usage:
#   batch-rename-template-to-base.sh [<version>] --why-file <path> [options]
#   batch-rename-template-to-base.sh [<version>] --why "<text>" [options]
#
# Options:
#   <version>              Target version on base repo (default v0.25.0)
#   --why-file <path>      PR body Why-section content (required, or use --why)
#   --why "<text>"         Inline alternative to --why-file
#   --issue <num>          Tracking issue number for PR body (optional)
#   --dry-run              Print what would be done; skip mutations
#   --only <r1,r2,...>     Limit to listed repos (relative paths, e.g. agent/ai_agent)
#   --skip <r1,r2,...>     Exclude listed repos
#   --continue-on-error    Keep going past failed repos; print summary at end
#   -h, --help             Show this help
#
# Designed to be run from the main session (not a subagent) because subagent
# sandbox blocks git push.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/log.sh disable=SC1091
source "${SCRIPT_DIR}/lib/log.sh"
readonly ORG="ycpss91255-docker"
readonly BASE_REPO="${ORG}/base"
readonly BASE_REMOTE="https://github.com/${BASE_REPO}.git"
readonly DEFAULT_VERSION="v0.25.0"

# roster-exempt: one-shot #263 Phase 6 migration (template/ -> .base subtree),
# already executed. The list records which repos that wave migrated.
readonly DEFAULT_REPOS=(
  agent/ai_agent
  agent/claude_code
  agent/codex_cli
  agent/gemini_cli
  app/realsense_humble
  app/realsense_noetic
  app/ros1_bridge
  app/sick_humble
  app/sick_noetic
  app/urg_node_humble
  app/urg_node_noetic
  env/ros2_distro
  env/ros_distro
)

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

main() {
  local version="${DEFAULT_VERSION}"
  local why_file=""
  local why_text=""
  local issue=""
  local dry_run=0
  local continue_on_error=0
  local only_csv=""
  local skip_csv=""

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --why-file) why_file="$2"; shift 2 ;;
      --why) why_text="$2"; shift 2 ;;
      --issue) issue="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --continue-on-error) continue_on_error=1; shift ;;
      --only) only_csv="$2"; shift 2 ;;
      --skip) skip_csv="$2"; shift 2 ;;
      v[0-9]*) version="$1"; shift ;;
      *) _log_fatal batch-rename unrecognised_arg arg="${1}"; usage; exit 2 ;;
    esac
  done

  if [[ -z "${why_file}" && -z "${why_text}" ]]; then
    _log_fatal batch-rename precondition_missing arg="--why-file|--why"
    exit 2
  fi
  if [[ -n "${why_file}" && ! -r "${why_file}" ]]; then
    _log_fatal batch-rename precondition_missing path="${why_file}" reason=not-readable
    exit 2
  fi

  local why
  if [[ -n "${why_file}" ]]; then
    why="$(cat -- "${why_file}")"
  else
    why="${why_text}"
  fi

  local repos=()
  if [[ -n "${only_csv}" ]]; then
    IFS=',' read -ra repos <<< "${only_csv}"
  else
    repos=("${DEFAULT_REPOS[@]}")
  fi
  if [[ -n "${skip_csv}" ]]; then
    local skip_set=" ${skip_csv//,/ } "
    local kept=() r
    for r in "${repos[@]}"; do
      if [[ "${skip_set}" != *" ${r} "* ]]; then
        kept+=("${r}")
      fi
    done
    repos=("${kept[@]}")
  fi

  local root
  root="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
  readonly root

  local branch="chore/rename-template-to-base-${version}"
  local issue_line=""
  if [[ -n "${issue}" ]]; then
    issue_line="Closes part of ${ORG}/docker_harness#${issue}."
  fi

  _log_info batch-rename summary phase=start version="${version}" branch="${branch}" dry_run="${dry_run}" count="${#repos[@]}"

  local failed=() skipped=() opened=()
  local pairs_file
  pairs_file="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${pairs_file}'" EXIT

  local repo
  for repo in "${repos[@]}"; do
    local reponame="${repo##*/}"
    local url="https://github.com/${ORG}/${reponame}.git"
    _log_info batch-rename processing_repo repo="${repo}"

    if [[ ! -d "${root}/${repo}" ]]; then
      _log_warn batch-rename repo_skipped repo="${repo}" reason=missing-local-dir
      skipped+=("${repo} (missing)")
      continue
    fi

    if (( dry_run )); then
      _log_info batch-rename dry_run_cmd repo="${repo}" url="${url}" branch="${branch}" version="${version}" action="rm template+subtree add .base+init+sed+PR"
      continue
    fi

    if rename_one "${root}/${repo}" "${url}" "${branch}" "${version}" "${reponame}" "${why}" "${issue_line}" "${pairs_file}"; then
      opened+=("${repo}")
    else
      local rc=$?
      if (( rc == 100 )); then
        skipped+=("${repo} (already migrated)")
      else
        failed+=("${repo}")
        if (( ! continue_on_error )); then
          _log_err batch-rename repo_failed repo="${repo}" rc="${rc}" action=abort
          break
        fi
      fi
    fi
  done

  local opened_pairs=()
  if [[ -s "${pairs_file}" ]]; then
    local line
    while IFS= read -r line; do
      [[ -n "${line}" ]] && opened_pairs+=("${line}")
    done < "${pairs_file}"
  fi

  _log_info batch-rename summary phase=end opened="${#opened[@]}" skipped="${#skipped[@]}" failed="${#failed[@]}"
  if (( ${#opened[@]} )); then
    printf '  opened:  %s\n' "${opened[@]}"
  fi
  if (( ${#skipped[@]} )); then
    printf '  skipped: %s\n' "${skipped[@]}"
  fi

  print_next_step_hint "${opened_pairs[@]}"

  if (( ${#failed[@]} )); then
    printf '  failed:  %s\n' "${failed[@]}"
    exit 1
  fi
}

# Rewrites `uses:` refs in main.yaml after the template -> base rename.
# Two passes:
#   1. Bump build-worker / release-worker @vX.Y.Z to the target ${version}
#      and switch org/repo to base. Matches optional pre-release suffix.
#   2. Generic catch-all: any remaining ${ORG}/template/ -> ${ORG}/base/.
#      Covers other reusable workflows (publish-worker, etc) that are
#      pinned to their own historical version and should NOT be rebumped
#      here -- only the org/repo segment changes.
sed_main_yaml_uses() {
  local file="$1"
  local version="$2"
  [[ -f "${file}" ]] || return 0
  sed -i -E \
    "s|${ORG}/template/\\.github/workflows/(build-worker\\|release-worker)\\.yaml@v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?|${ORG}/base/.github/workflows/\\1.yaml@${version}|g" \
    "${file}"
  sed -i "s|${ORG}/template/|${ORG}/base/|g" "${file}"
}

# Sed downstream Dockerfile + main.yaml + 4-language READMEs.
# Each call is best-effort: missing files are no-ops, not errors.
sed_consumer_refs() {
  local dir="$1"
  local version="$2"

  if [[ -f "${dir}/Dockerfile" ]]; then
    # Broad sed: any `template/` path literal in the Dockerfile, not
    # just `COPY template/`. Multi-source COPY lines like
    # `COPY .base/x template/y /dst/` had a second `template/` after
    # the COPY token that the prior narrow pattern missed -- which
    # broke the Phase 6 fanout on ros1_bridge / urg_node_humble /
    # ros{2,}_distro until each Dockerfile got a follow-up fix
    # commit. Broaden so future re-runs cover those lines on the
    # first pass.
    sed -i 's|template/|.base/|g' "${dir}/Dockerfile"
  fi

  sed_main_yaml_uses "${dir}/.github/workflows/main.yaml" "${version}"

  local readme
  for readme in README.md doc/README.zh-TW.md doc/README.zh-CN.md doc/README.ja.md; do
    [[ -f "${dir}/${readme}" ]] || continue
    sed -i 's|template/|.base/|g' "${dir}/${readme}"
    sed -i "s|${ORG}/template|${ORG}/base|g" "${dir}/${readme}"
  done
}

# Per-repo migration. Returns:
#   0   - PR opened
#   100 - repo already on .base/ (no work to do)
#   1   - any other failure
rename_one() {
  local dir="$1"
  local url="$2"
  local branch="$3"
  local version="$4"
  local reponame="$5"
  local why="$6"
  local issue_line="$7"
  local pairs_file="${8:-}"

  cd "${dir}"

  git fetch "${url}" main || return 1
  git checkout -B main FETCH_HEAD || return 1

  if [[ -d ".base" && ! -d "template" ]]; then
    _log_info batch-rename repo_skipped repo="${reponame}" reason=already-on-base
    return 100
  fi

  git checkout -B "${branch}" || return 1

  # Step 1: drop old subtree
  if [[ -d "template" ]]; then
    git rm -r template >/dev/null || return 1
    git commit -m "chore: remove template/ subtree (superseded by .base/, refs ${ORG}/base#263)" \
      || return 1
  fi

  # Step 2: fresh subtree add against renamed upstream
  git subtree add --prefix=.base "${BASE_REMOTE}" "${version}" --squash \
    -m "chore: add .base/ subtree at ${version} (from ${BASE_REPO}, refs ${ORG}/base#263)" \
    || return 1

  # Step 3: relocate per-repo setup.conf override if it exists at root
  if [[ -f "setup.conf" ]]; then
    mkdir -p config/docker
    git mv setup.conf config/docker/setup.conf || return 1
    git commit -m "chore: move setup.conf to config/docker/ (post-#262, ${ORG}/base v0.25.0)" \
      || return 1
  fi

  # Step 4: resync symlinks via auto-detect init.sh
  ./.base/init.sh || return 1

  # Step 5-7: sed Dockerfile + main.yaml + READMEs
  sed_consumer_refs "${dir}" "${version}"

  git add -A
  if git diff --cached --quiet; then
    _log_info batch-rename processing_repo repo="${reponame}" detail=no-sed-needed
  else
    git commit -m "chore: migrate Dockerfile / main.yaml / README refs to .base/ + ${BASE_REPO}@${version}" \
      || return 1
  fi

  git push -u origin "${branch}" || return 1

  local pr_body_file
  pr_body_file="$(mktemp)"
  cat > "${pr_body_file}" <<EOF
## Why

${why}

${issue_line}

## What changed

- Old \`template/\` subtree removed (\`git rm -r template/\`).
- Fresh \`.base/\` subtree added from \`${BASE_REPO}\` at tag \`${version}\` (\`git subtree add --prefix=.base ${BASE_REMOTE} ${version} --squash\`). Future \`make -f Makefile.ci upgrade VERSION=vX.Y.Z\` keeps working because the new \`git-subtree-dir: .base\` marker is born from this add commit.
- Per-repo \`setup.conf\` (if previously at repo root) moved to \`config/docker/setup.conf\` per #262 / base v0.25.0.
- Symlinks (\`build.sh\` / \`run.sh\` / \`exec.sh\` / \`stop.sh\` / \`Makefile\` / \`.hadolint.yaml\`) re-pointed through \`.base/\` via \`./.base/init.sh\` (subtree-prefix auto-detect from base v0.25.0).
- \`Dockerfile\` \`COPY template/\` lines, \`.github/workflows/main.yaml\` \`uses:\` refs, and 4-language READMEs all switched to \`.base/\` + \`${BASE_REPO}\`.

## Test plan

- [ ] CI green on this PR (existing \`call-docker-build\` job will rebuild against \`.base/\` paths).
- [ ] After merge: \`make -f Makefile.ci upgrade-check\` and \`make -f Makefile.ci upgrade\` continue to work for future \`${BASE_REPO}\` tags.
EOF

  local pr_url
  if pr_url="$(gh pr create --repo "${ORG}/${reponame}" \
    --head "${branch}" --base main \
    --title "chore: migrate template/ subtree to .base/ (${BASE_REPO}@${version})" \
    --body-file "${pr_body_file}" 2>&1)"; then
    _log_info batch-rename pr_opened repo="${reponame}" url="${pr_url}"
    if [[ -n "${pairs_file}" ]]; then
      local pr_num
      pr_num="$(printf '%s' "${pr_url}" | grep -oE '/pull/[0-9]+' | head -1 | sed 's|/pull/||')"
      if [[ -n "${pr_num}" ]]; then
        printf '%s:%s\n' "${reponame}" "${pr_num}" >> "${pairs_file}"
      fi
    fi
    rm -f "${pr_body_file}"
    return 0
  else
    _log_err batch-rename repo_failed repo="${reponame}" action=gh-pr-create detail="${pr_url}"
    rm -f "${pr_body_file}"
    return 1
  fi
}

print_next_step_hint() {
  local pairs=("$@")
  (( ${#pairs[@]} )) || return 0
  echo
  echo "next: wait CI then merge:"
  local filters=""
  local p reponame
  for p in "${pairs[@]}"; do
    reponame="${p%%:*}"
    case "${reponame}" in
      ros_distro|ros2_distro) filters+=" --check-filter '${reponame}=.name==\"ci-passed\"'" ;;
      ros1_bridge) filters+=" --check-filter '${reponame}=.name==\"ci-summary\"'" ;;
    esac
  done
  echo "  ${SCRIPT_DIR}/wait-pr-ci-batch.sh ${pairs[*]} \\"
  echo "    --check-filter '.name==\"call-docker-build / docker-build\"'${filters}"
  echo "  ${SCRIPT_DIR}/batch-pr-merge.sh ${pairs[*]}"
}

main "$@"
