#!/usr/bin/env bats

# .claude/test/ci.sh bind-mounts the live worktree (${REPO_ROOT}:/work) into
# the test/lint containers. Those runs must NOT execute as root, or CPython
# litters root-owned .claude/scripts/__pycache__/*.pyc into the mount and
# breaks host-side `git worktree remove` (refs #252). The fix routes every
# worktree-mounting `docker run` through the WORKTREE_MOUNT_FLAGS array
# (--user "$(id -u):$(id -g)" + -e PYTHONDONTWRITEBYTECODE=1). This spec is a
# lexical guard so a future edit that adds a raw worktree-mounting run, or
# drops a flag, fails CI.

load '../lib/test_helper'

# Resolve the repo root from HOOKS_DIR (= <root>/.claude/hooks).
repo_root() {
  cd "${HOOKS_DIR}/../.." && pwd
}

ci_sh() {
  echo "$(repo_root)/.claude/test/ci.sh"
}

@test "ci.sh exists and is readable" {
  [ -f "$(ci_sh)" ] || { echo "ci.sh not found at $(ci_sh)" >&2; return 1; }
}

@test "WORKTREE_MOUNT_FLAGS carries --user and PYTHONDONTWRITEBYTECODE" {
  local def
  def="$(grep -E '^WORKTREE_MOUNT_FLAGS=\(' "$(ci_sh)")" || {
    echo "WORKTREE_MOUNT_FLAGS array not defined in ci.sh" >&2; return 1; }
  echo "${def}" | grep -q -- '--user' \
    || { echo "WORKTREE_MOUNT_FLAGS missing --user: ${def}" >&2; return 1; }
  echo "${def}" | grep -q 'PYTHONDONTWRITEBYTECODE=1' \
    || { echo "WORKTREE_MOUNT_FLAGS missing PYTHONDONTWRITEBYTECODE=1: ${def}" >&2; return 1; }
}

@test "every worktree-mounting docker run routes through WORKTREE_MOUNT_FLAGS" {
  # Any `docker run` line that bind-mounts the live worktree (REPO_ROOT:/work)
  # must also expand the flags array. A raw one would run as root again.
  local offenders
  offenders="$(grep -nE 'docker run' "$(ci_sh)" \
    | grep -F '${REPO_ROOT}:/work' \
    | grep -vF '${WORKTREE_MOUNT_FLAGS[@]}' || true)"
  [ -z "${offenders}" ] || {
    echo "worktree-mounting docker run bypasses WORKTREE_MOUNT_FLAGS:" >&2
    echo "${offenders}" >&2
    return 1
  }
}
