#!/usr/bin/env bash
# log-allow:script -- test-harness driver; emits raw tool output (docker / shellcheck / hadolint / audit scripts), not _log_* records.
#
# docker_harness test-infra driver -- the single source of truth for the
# harness gate, invoked BOTH locally (via .claude/test/justfile recipes,
# e.g. `just -f .claude/test/justfile check`) AND from CI (.github/
# workflows/test.yaml runs `.claude/test/ci.sh <target>` directly, so the
# runner needs no `just`). Mirrors base's pattern: CI calls the driver,
# `just` is a local convenience wrapper over the same driver, so the two
# can never drift (refs #220 make->just migration).
#
# All docker-backed targets run inside the .claude/test/Dockerfile image so
# behaviour matches CI exactly ("verify-via-Docker" CLAUDE.md rule).
#
# Usage: ci.sh <target>
#   build             build the test docker image
#   test              run bats specs (unit/integration/system/acceptance) inside docker
#   lint              shellcheck all hook + helper scripts inside docker
#   hadolint          hadolint the test Dockerfile
#   tree-check        audit CONTEXT.md .claude/ tree vs filesystem (host)
#   ceiling-check     audit CLAUDE.md line / section ceilings (host)
#   log-helper-check  enforce lib/log.sh adoption in .claude/scripts (host)
#   doc-count-check   assert doc/test/*.md matches the spec tree (host)
#   check             lint + hadolint + test + tree-check + ceiling-check +
#                     log-helper-check + doc-count-check
#   clean             remove the test image
#   help              list targets

set -euo pipefail

readonly IMAGE='docker_harness-test:local'

# Pinned deliberately -- do NOT float this back to `latest-alpine` as a
# tidy-up. hadolint is a linter whose rule set grows between releases, so a
# floating tag lets an upstream publish turn `main` (and every open PR at
# once) red with no commit in this repo: 2.15 added DL3066 and did exactly
# that, and the failure surfaces attached to whatever PR is in flight
# (refs #263). Same convention as base's `rhysd/actionlint:1.7.7`. Bump on
# purpose, in its own commit, after re-running `ci.sh hadolint`.
readonly HADOLINT_IMAGE='hadolint/hadolint:v2.15.1-alpine'

# Flags for the docker runs that bind-mount the live worktree read-write.
# Without them the container runs as root and CPython writes bytecode caches
# (.claude/scripts/__pycache__/*.pyc) into the mount as root, which then breaks
# `git worktree remove` / host-side cleanup (refs #252):
#   --user maps writes to the invoking host user (also sidesteps git's
#          "dubious ownership" on the host-owned /work repo);
#   PYTHONDONTWRITEBYTECODE stops the .pyc litter at the source (CI is a single
#          run and gains nothing from a bytecode cache).
# id -u/-g are unset in CI's GitHub-hosted runner default (already the invoking
# user there), but harmless; locally they map to the developer's uid/gid.
WORKTREE_MOUNT_FLAGS=(--user "$(id -u):$(id -g)" -e PYTHONDONTWRITEBYTECODE=1)
readonly WORKTREE_MOUNT_FLAGS

# This script lives at <repo>/.claude/test/ci.sh; repo root is two up.
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
readonly REPO_ROOT="${TEST_DIR%/.claude/test}"

t_build() {
  # Build context = repo root; Dockerfile COPY paths stay relative to it.
  #
  # APK_MIRROR is forwarded only when the caller set it, so the image's own
  # default stays the single place the upstream host is named. Passing it
  # unconditionally would put an empty --build-arg in front of that default
  # on every machine that does not need one.
  local _args=()
  if [ -n "${APK_MIRROR:-}" ]; then
    _args=(--build-arg "APK_MIRROR=${APK_MIRROR}")
  fi
  docker build "${_args[@]}" -f "${TEST_DIR}/Dockerfile" -t "${IMAGE}" "${REPO_ROOT}"
}

t_test() {
  t_build
  # -v mounts the live worktree so bats runs the working-tree specs, not the
  # build-time COPY baked into the image (refs #214). The local-CI-pass
  # marker is written by ci-and-stamp.sh, not here (refs #208).
  docker run --rm "${WORKTREE_MOUNT_FLAGS[@]}" -v "${REPO_ROOT}:/work" "${IMAGE}"
}

# lint_targets <root> -- print, one per line and repo-relative, the shell
# scripts the lint gate covers: the git-TRACKED *.sh under .claude/hooks
# and .claude/scripts (lib/ included).
#
# WHY tracked and not a glob: the local run bind-mounts the live worktree
# (deliberately, refs #214) while CI checks out a clean one, so a glob
# inside the container made the two gates answer different questions --
# and the local one was the useless answer, red for weeks over fifteen
# untracked one-off scripts CI never sees (refs #282). Computing the list
# from git keeps both runs on the same set; git runs on the HOST, where
# the repo and git are, and only the resulting paths enter the container.
#
# A path git still tracks but the worktree no longer has is dropped: the
# container lints the mount, so naming it would fail the gate on a file
# that is not there.
lint_targets() {
  local root="$1" f
  git -C "${root}" ls-files -z -- \
    '.claude/hooks/*.sh' '.claude/scripts/*.sh' '.claude/scripts/lib/*.sh' \
    | while IFS= read -r -d '' f; do
        [[ -f "${root}/${f}" ]] || continue
        printf '%s\n' "${f}"
      done
}

t_lint() {
  t_build
  local targets=()
  mapfile -t targets < <(lint_targets "${REPO_ROOT}")
  if (( ${#targets[@]} == 0 )); then
    printf 'ci.sh: no tracked shell scripts to lint under %s\n' "${REPO_ROOT}" >&2
    return 1
  fi
  # -v mounts the live worktree so shellcheck lints the working-tree
  # content of those scripts, not the build-time COPY (refs #214).
  docker run --rm "${WORKTREE_MOUNT_FLAGS[@]}" -v "${REPO_ROOT}:/work" \
    --entrypoint shellcheck "${IMAGE}" "${targets[@]/#//work/}"
}

t_hadolint() {
  docker run --rm -i \
    -v "${REPO_ROOT}/.hadolint.yaml:/.hadolint.yaml:ro" \
    "${HADOLINT_IMAGE}" \
    hadolint --config /.hadolint.yaml - < "${TEST_DIR}/Dockerfile"
}

t_tree_check() {
  "${REPO_ROOT}/.claude/scripts/check-claude-md-tree.sh" "${REPO_ROOT}/CONTEXT.md"
}

t_ceiling_check() {
  "${REPO_ROOT}/.claude/scripts/check-claude-md-ceiling.sh" "${REPO_ROOT}/CLAUDE.md"
}

t_log_helper_check() {
  "${REPO_ROOT}/.claude/scripts/check-log-helper-usage.sh" --scripts-dir "${REPO_ROOT}/.claude/scripts"
}

# Read-only twin of .claude/scripts/sync-doc-test-counts.sh: regenerates the
# doc/test catalogs into a scratch copy and diffs. It shares the generator's
# code path on purpose -- a separately-implemented checker is how the two
# older drift checkers ended up matching nothing at all (refs #265).
t_doc_count_check() {
  "${REPO_ROOT}/.claude/scripts/sync-doc-test-counts.sh" --check "${REPO_ROOT}"
}

t_check() {
  t_lint
  t_hadolint
  t_test
  t_tree_check
  t_ceiling_check
  t_log_helper_check
  t_doc_count_check
}

t_clean() {
  docker image rm "${IMAGE}" 2>/dev/null || true
}

t_help() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local target="${1:-help}"
  case "${target}" in
    build)            t_build ;;
    test)             t_test ;;
    lint)             t_lint ;;
    hadolint)         t_hadolint ;;
    tree-check)       t_tree_check ;;
    ceiling-check)    t_ceiling_check ;;
    log-helper-check) t_log_helper_check ;;
    doc-count-check)  t_doc_count_check ;;
    check)            t_check ;;
    clean)            t_clean ;;
    help|-h|--help)   t_help ;;
    *) printf 'ci.sh: unknown target: %s\n\n' "${target}" >&2; t_help >&2; exit 2 ;;
  esac
}

# Sourcing the driver exposes its helpers (lint_targets) without running a
# target -- that is how the bats specs exercise them.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
