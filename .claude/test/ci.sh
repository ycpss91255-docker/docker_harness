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
#   test              run bats specs (smoke + integration) inside docker
#   lint              shellcheck all hook + helper scripts inside docker
#   hadolint          hadolint the test Dockerfile
#   tree-check        audit CONTEXT.md .claude/ tree vs filesystem (host)
#   ceiling-check     audit CLAUDE.md line / section ceilings (host)
#   log-helper-check  enforce lib/log.sh adoption in .claude/scripts (host)
#   check             lint + hadolint + test + tree-check + ceiling-check + log-helper-check
#   clean             remove the test image
#   help              list targets

set -euo pipefail

readonly IMAGE='docker_harness-test:local'
readonly HADOLINT_IMAGE='hadolint/hadolint:latest-alpine'

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
  docker build -f "${TEST_DIR}/Dockerfile" -t "${IMAGE}" "${REPO_ROOT}"
}

t_test() {
  t_build
  # -v mounts the live worktree so bats runs the working-tree specs, not the
  # build-time COPY baked into the image (refs #214). The local-CI-pass
  # marker is written by ci-and-stamp.sh, not here (refs #208).
  docker run --rm "${WORKTREE_MOUNT_FLAGS[@]}" -v "${REPO_ROOT}:/work" "${IMAGE}"
}

t_lint() {
  t_build
  # -v mounts the live worktree so shellcheck lints the working-tree
  # scripts, not the build-time COPY (refs #214).
  docker run --rm "${WORKTREE_MOUNT_FLAGS[@]}" -v "${REPO_ROOT}:/work" \
    --entrypoint sh "${IMAGE}" -c \
    'shellcheck /work/.claude/hooks/*.sh /work/.claude/scripts/*.sh /work/.claude/scripts/lib/*.sh'
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

t_check() {
  t_lint
  t_hadolint
  t_test
  t_tree_check
  t_ceiling_check
  t_log_helper_check
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
    check)            t_check ;;
    clean)            t_clean ;;
    help|-h|--help)   t_help ;;
    *) printf 'ci.sh: unknown target: %s\n\n' "${target}" >&2; t_help >&2; exit 2 ;;
  esac
}

main "$@"
