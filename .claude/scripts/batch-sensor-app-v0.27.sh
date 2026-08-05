#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

#
# One-shot fanout for the 5 sensor-app repos still on
# ycpss91255-docker/base v0.23.0 with `template/` subtree:
#
#   - app/realsense_humble
#   - app/realsense_noetic
#   - app/sick_humble
#   - app/sick_noetic
#   - app/urg_node_noetic
#
# Migrates each repo to v0.27.0 in one PR by combining:
#
#   1. Rename `template/` -> `.base/` (same mechanics as
#      `batch-rename-template-to-base.sh`).
#   2. Dockerfile restructure to align with v0.27 `Dockerfile.example`:
#      - Switch `ARG CONFIG_SRC` from `template/config` (now-stale path)
#        to `config` (repo-local layered override per template#254).
#      - Add `ARG SETUP_DIR="/tmp/setup"` for the build-time pip /
#        setup scaffolding split (template#261).
#      - Add two new COPY lines: `.base/config` (layer 1 default) and
#        `.base/dockerfile/setup` (build-time scaffolding).
#      - Switch `RUN "${CONFIG_DIR}"/pip/setup.sh` to
#        `RUN "${SETUP_DIR}"/pip/setup.sh`.
#      - Add bashrc.d drop-in handling to the shell-setup RUN block.
#      - Clear SETUP_DIR alongside CONFIG_DIR at end of shell-setup
#        RUN.
#
# The Dockerfile transform is uniform across all 5 sensor-app repos
# (confirmed by a `grep -nE 'CONFIG_DIR|CONFIG_SRC|RUN.*pip|RUN cat
# .*bashrc|sudo rm -rf'` audit on 2026-05-13; same line shape, only
# line numbers differ). Each sed has a unique anchor and is
# idempotent-safe so a re-run on the same branch leaves the file
# unchanged after the first invocation.
#
# Usage:
#   batch-sensor-app-v0.27.sh --why-file <path> [options]
#   batch-sensor-app-v0.27.sh --why "<text>" [options]
#
# Options:
#   --why-file <path>      PR body Why-section content (required, or use --why)
#   --why "<text>"         Inline alternative to --why-file
#   --issue <num>          Tracking issue number for PR body (optional)
#   --dry-run              Print what would be done; skip mutations
#   --only <r1,r2,...>     Limit to listed repos (relative paths)
#   --skip <r1,r2,...>     Exclude listed repos
#   --continue-on-error    Keep going past failed repos; print summary at end
#   -h, --help             Show this help
#
# Designed to be run from the main session (not a subagent) because
# subagent sandbox blocks git push.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/log.sh disable=SC1091
source "${SCRIPT_DIR}/lib/log.sh"
readonly ORG="ycpss91255-docker"
readonly BASE_REPO="${ORG}/base"
readonly BASE_REMOTE="https://github.com/${BASE_REPO}.git"
readonly TARGET_VERSION="v0.27.0"
readonly BRANCH="chore/sensor-app-${TARGET_VERSION}"

# roster-exempt: one-shot v0.27.0 sensor-app fanout, already executed. The
# list records which five repos that wave touched, under their then-names.
readonly DEFAULT_REPOS=(
  app/realsense_humble
  app/realsense_noetic
  app/sick_humble
  app/sick_noetic
  app/urg_node_noetic
)

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

# Sensor-app Dockerfile structural transform. Each sed has a unique
# anchor and runs in a defined order so the file ends in the v0.27
# Dockerfile.example shape. Safe to re-run.
#
# shellcheck disable=SC2016
#   SC2016 fires on every sed pattern below: the `${USER}` / `${GROUP}`
#   / `${HOME}` / `${CONFIG_DIR}` / `${SETUP_DIR}` tokens are literal
#   text in the Dockerfile, intentionally NOT expanded by the shell.
# shellcheck disable=SC1003
#   SC1003 fires on the `\\` (literal backslash) at the end of each
#   sed `a\` insertion line. The trailing backslash is the Dockerfile
#   line-continuation character we're inserting, again intentional.
transform_dockerfile() {
  local dockerfile="$1"
  [[ -f "${dockerfile}" ]] || return 0

  # 1) CONFIG_SRC: ".base/config" (post-rename) -> "config" (repo-local).
  sed -i 's|^ARG CONFIG_SRC="\.base/config"$|ARG CONFIG_SRC="config"|' "${dockerfile}"

  # 2) Add ARG SETUP_DIR right after ARG CONFIG_DIR (only if not already present).
  if ! grep -q '^ARG SETUP_DIR=' "${dockerfile}"; then
    sed -i '/^ARG CONFIG_DIR="\/tmp\/config"$/a\ARG SETUP_DIR="/tmp/setup"' "${dockerfile}"
  fi

  # 3) Before the CONFIG_SRC COPY, add layer-1 ".base/config" COPY
  #    (only if not already present).
  if ! grep -q '^COPY --chown="\${USER}":"\${GROUP}" --chmod=0755 \.base/config "\${CONFIG_DIR}"$' "${dockerfile}"; then
    sed -i '/^COPY --chown="\${USER}":"\${GROUP}" --chmod=0755 "\${CONFIG_SRC}" "\${CONFIG_DIR}"$/i\COPY --chown="${USER}":"${GROUP}" --chmod=0755 .base/config "${CONFIG_DIR}"' "${dockerfile}"
  fi

  # 4) After the CONFIG_SRC COPY, add ".base/dockerfile/setup" COPY
  #    (only if not already present).
  if ! grep -q '^COPY --chmod=0755 \.base/dockerfile/setup "\${SETUP_DIR}"$' "${dockerfile}"; then
    sed -i '/^COPY --chown="\${USER}":"\${GROUP}" --chmod=0755 "\${CONFIG_SRC}" "\${CONFIG_DIR}"$/a\COPY --chmod=0755 .base/dockerfile/setup "${SETUP_DIR}"' "${dockerfile}"
  fi

  # 5) Switch pip RUN to SETUP_DIR.
  sed -i 's|^RUN "\${CONFIG_DIR}"/pip/setup\.sh$|RUN "${SETUP_DIR}"/pip/setup.sh|' "${dockerfile}"

  # 6) bashrc.d drop-in handling. Inserted as three lines AFTER the
  #    chown bashrc anchor; sed `a\` repeats with the same anchor put
  #    new lines directly after the anchor in reverse-of-call order, so
  #    invoke in the order needed for the final file layout (chown
  #    bashrc.d last appended -> ends up immediately after the cp line).
  if ! grep -q 'mkdir -p "\${HOME}/\.bashrc\.d"' "${dockerfile}"; then
    sed -i '/^    chown "\${USER}":"\${GROUP}" "\${HOME}\/\.bashrc" && \\$/a\    chown -R "${USER}":"${GROUP}" "${HOME}/.bashrc.d" \&\& \\' "${dockerfile}"
    sed -i '/^    chown "\${USER}":"\${GROUP}" "\${HOME}\/\.bashrc" && \\$/a\    cp -n "${CONFIG_DIR}"/shell/bashrc.d/*.sh "${HOME}/.bashrc.d/" 2>/dev/null || true \&\& \\' "${dockerfile}"
    sed -i '/^    chown "\${USER}":"\${GROUP}" "\${HOME}\/\.bashrc" && \\$/a\    mkdir -p "${HOME}/.bashrc.d" \&\& \\' "${dockerfile}"
  fi

  # 7) Clear SETUP_DIR alongside CONFIG_DIR.
  sed -i 's|^    sudo rm -rf "\${CONFIG_DIR}"$|    sudo rm -rf "${CONFIG_DIR}" "${SETUP_DIR}"|' "${dockerfile}"
}

# Same uses: rewrite logic as batch-rename-template-to-base.sh.
sed_main_yaml_uses() {
  local file="$1"
  local version="$2"
  [[ -f "${file}" ]] || return 0
  sed -i -E \
    "s|${ORG}/template/\\.github/workflows/(build-worker\\|release-worker)\\.yaml@v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?|${ORG}/base/.github/workflows/\\1.yaml@${version}|g" \
    "${file}"
  sed -i "s|${ORG}/template/|${ORG}/base/|g" "${file}"
}

# Mechanical sed for Dockerfile + READMEs (template/ -> .base/),
# matches batch-rename-template-to-base.sh. After this runs, the
# sensor-app-specific transform runs on top to convert the mechanical
# .base/config single-COPY pattern into the v0.27 layered shape.
sed_consumer_refs() {
  local dir="$1"
  local version="$2"

  if [[ -f "${dir}/Dockerfile" ]]; then
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

migrate_one() {
  local dir="$1"
  local url="$2"
  local reponame="$3"
  local why="$4"
  local issue_line="$5"
  local pairs_file="${6:-}"

  cd "${dir}"

  git fetch "${url}" main || return 1
  git checkout -B main FETCH_HEAD || return 1

  if [[ -d ".base" && ! -d "template" ]]; then
    _log_info batch-sensor-v0.27 repo_skipped repo="${reponame}" reason=already-on-base
    return 100
  fi

  git checkout -B "${BRANCH}" || return 1

  # Step 1: drop old subtree
  if [[ -d "template" ]]; then
    git rm -r template >/dev/null || return 1
    git commit -m "chore: remove template/ subtree (superseded by .base/, refs ${BASE_REPO}#263)" \
      || return 1
  fi

  # Step 2: fresh subtree add at v0.27.0
  git subtree add --prefix=.base "${BASE_REMOTE}" "${TARGET_VERSION}" --squash \
    -m "chore: add .base/ subtree at ${TARGET_VERSION} (from ${BASE_REPO}, refs ${BASE_REPO}#263)" \
    || return 1

  # Step 3: relocate per-repo setup.conf if at root
  if [[ -f "setup.conf" ]]; then
    mkdir -p config/docker
    git mv setup.conf config/docker/setup.conf || return 1
    git commit -m "chore: move setup.conf to config/docker/ (post-#262, ${BASE_REPO} v0.25.0)" \
      || return 1
  fi

  # Step 4: resync symlinks
  ./.base/init.sh || return 1

  # Step 5-7: mechanical sed for Dockerfile/main.yaml/READMEs
  sed_consumer_refs "${dir}" "${TARGET_VERSION}"

  # Step 8: sensor-app-specific Dockerfile structural transform.
  transform_dockerfile "${dir}/Dockerfile"

  git add -A
  if git diff --cached --quiet; then
    _log_info batch-sensor-v0.27 processing_repo repo="${reponame}" detail=no-sed-needed
  else
    git commit -m "chore: migrate Dockerfile to v0.27 layered config + SETUP_DIR (refs ${BASE_REPO}#263)" \
      || return 1
  fi

  git push -u origin "${BRANCH}" || return 1

  local pr_body_file
  pr_body_file="$(mktemp)"
  cat > "${pr_body_file}" <<EOF
## Why

${why}

${issue_line}

## What changed

- Old \`template/\` subtree removed (\`git rm -r template/\`).
- Fresh \`.base/\` subtree added from \`${BASE_REPO}\` at tag \`${TARGET_VERSION}\` (\`git subtree add --prefix=.base ${BASE_REMOTE} ${TARGET_VERSION} --squash\`). Future \`make -f Makefile.ci upgrade VERSION=vX.Y.Z\` keeps working because the new \`git-subtree-dir: .base\` marker is born from this add commit.
- Symlinks (\`build.sh\` / \`run.sh\` / \`exec.sh\` / \`stop.sh\` / \`Makefile\` / \`.hadolint.yaml\` / \`setup.sh\` / \`setup_tui.sh\`) re-pointed through \`.base/\` via \`./.base/init.sh\` (subtree-prefix auto-detect from base v0.25.0).
- \`.github/workflows/main.yaml\` \`uses:\` refs switched to \`${BASE_REPO}/.github/workflows/...@${TARGET_VERSION}\`.
- 4-language READMEs (\`README.md\` + \`doc/README.{zh-TW,zh-CN,ja}.md\`) directory-tree references switched to \`.base/\`.
- \`Dockerfile\` restructured to v0.27 \`Dockerfile.example\` shape:
  - \`ARG CONFIG_SRC\` switched from \`template/config\` to \`config\` (repo-local layered override per template#254).
  - New \`ARG SETUP_DIR="/tmp/setup"\` for the build-time pip / setup scaffolding split (template#261).
  - Added \`COPY .base/config\` (layer-1 default) before the existing \`CONFIG_SRC\` COPY (layer-2 override).
  - Added \`COPY .base/dockerfile/setup\` for build-time scaffolding.
  - \`RUN "\${CONFIG_DIR}"/pip/setup.sh\` switched to \`RUN "\${SETUP_DIR}"/pip/setup.sh\`.
  - Shell-setup RUN block gained bashrc.d drop-in handling and clears \`\${SETUP_DIR}\` alongside \`\${CONFIG_DIR}\`.

## Test plan

- [ ] CI green on this PR (\`call-docker-build / docker-build\` rebuilds against the new layout).
- [ ] After merge: \`make -f Makefile.ci upgrade-check\` and \`make -f Makefile.ci upgrade\` continue to work for future \`${BASE_REPO}\` tags.
EOF

  local pr_url
  if pr_url="$(gh pr create --repo "${ORG}/${reponame}" \
    --head "${BRANCH}" --base main \
    --title "chore: migrate to ${BASE_REPO}@${TARGET_VERSION} (sensor-app v0.27 layered config + SETUP_DIR)" \
    --body-file "${pr_body_file}" 2>&1)"; then
    _log_info batch-sensor-v0.27 pr_opened repo="${reponame}" url="${pr_url}"
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
    _log_err batch-sensor-v0.27 repo_failed repo="${reponame}" action=gh-pr-create detail="${pr_url}"
    rm -f "${pr_body_file}"
    return 1
  fi
}

print_next_step_hint() {
  local pairs=("$@")
  (( ${#pairs[@]} )) || return 0
  echo
  echo "next: wait CI then merge:"
  echo "  ${SCRIPT_DIR}/wait-pr-ci-batch.sh ${pairs[*]} \\"
  echo "    --check-filter '.name==\"call-docker-build / docker-build\"'"
  echo "  ${SCRIPT_DIR}/batch-pr-merge.sh ${pairs[*]}"
}

main() {
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
      *) _log_fatal batch-sensor-v0.27 unrecognised_arg arg="${1}"; usage; exit 2 ;;
    esac
  done

  local why
  if [[ -n "${why_file}" ]]; then
    [[ -f "${why_file}" ]] || { _log_fatal batch-sensor-v0.27 precondition_missing path="${why_file}" reason=not-found; exit 2; }
    why="$(< "${why_file}")"
  elif [[ -n "${why_text}" ]]; then
    why="${why_text}"
  else
    _log_fatal batch-sensor-v0.27 precondition_missing arg="--why-file|--why"
    usage
    exit 2
  fi

  local issue_line=""
  if [[ -n "${issue}" ]]; then
    issue_line="Refs ${BASE_REPO}#${issue}."
  fi

  local repos=()
  local r
  for r in "${DEFAULT_REPOS[@]}"; do
    if [[ -n "${only_csv}" ]]; then
      [[ ",${only_csv}," == *",${r},"* ]] || continue
    fi
    if [[ -n "${skip_csv}" ]]; then
      [[ ",${skip_csv}," == *",${r},"* ]] && continue
    fi
    repos+=("${r}")
  done

  if (( ${#repos[@]} == 0 )); then
    _log_fatal batch-sensor-v0.27 precondition_missing arg="<repos>" reason=none-selected
    exit 2
  fi

  _log_info batch-sensor-v0.27 summary phase=start count="${#repos[@]}" base_repo="${BASE_REPO}" version="${TARGET_VERSION}" branch="${BRANCH}"

  local pairs_file
  pairs_file="$(mktemp)"

  local opened=()
  local skipped=()
  local failed=()

  local workspace_root
  workspace_root="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
  for r in "${repos[@]}"; do
    local dir="${workspace_root}/${r}"
    local reponame="${r##*/}"
    local url="https://github.com/${ORG}/${reponame}.git"

    [[ -d "${dir}" ]] || { _log_err batch-sensor-v0.27 repo_failed repo="${reponame}" reason=dir-missing path="${dir}"; failed+=("${reponame}"); continue; }

    if (( dry_run )); then
      _log_info batch-sensor-v0.27 dry_run_cmd repo="${reponame}" url="${url}" version="${TARGET_VERSION}" action="rm template+subtree add+init+sed+transform+PR"
      continue
    fi

    local rc=0
    migrate_one "${dir}" "${url}" "${reponame}" "${why}" "${issue_line}" "${pairs_file}" || rc=$?
    case "${rc}" in
      0)   opened+=("${reponame}") ;;
      100) skipped+=("${reponame}") ;;
      *)
        failed+=("${reponame}")
        if (( ! continue_on_error )); then
          _log_err batch-sensor-v0.27 repo_failed repo="${reponame}" rc="${rc}" action=abort
          break
        fi
        ;;
    esac
  done

  local opened_pairs=()
  if [[ -s "${pairs_file}" ]]; then
    mapfile -t opened_pairs < "${pairs_file}"
  fi
  rm -f "${pairs_file}"

  _log_info batch-sensor-v0.27 summary phase=end opened="${#opened[@]}" skipped="${#skipped[@]}" failed="${#failed[@]}"
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

main "$@"
