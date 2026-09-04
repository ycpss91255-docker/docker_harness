#!/usr/bin/env bats

# .claude/test/ci.sh lint must cover the same file set CI covers (refs
# #282). Both run this driver, but the local run bind-mounts the LIVE
# worktree (deliberately, refs #214) while CI checks out a clean one --
# so a `*.sh` glob made the two answer different questions, and the local
# answer was the useless one: fifteen untracked one-off scripts kept
# `lint` red on a clean `main` for weeks.
#
# The set is therefore the git-TRACKED shell scripts, computed on the
# host (where git is) by `lint_targets` and handed to the container.

load '../lib/test_helper'

repo_root() {
  cd "${HOOKS_DIR}/../.." && pwd
}

ci_sh() {
  echo "$(repo_root)/.claude/test/ci.sh"
}

# targets <root> -- run ci.sh's lint_targets against <root>.
targets() {
  run bash -c "source '$(ci_sh)'; lint_targets '$1'"
}

# mk_repo -- temp git repo carrying one tracked script per lint location.
mk_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "${dir}" init -q -b main
  git -C "${dir}" config user.email t@t
  git -C "${dir}" config user.name t
  mkdir -p "${dir}/.claude/hooks" "${dir}/.claude/scripts/lib"
  echo "echo hook" > "${dir}/.claude/hooks/a_hook.sh"
  echo "echo script" > "${dir}/.claude/scripts/a-script.sh"
  echo "echo lib" > "${dir}/.claude/scripts/lib/a-lib.sh"
  echo "notes" > "${dir}/.claude/scripts/NOTES.md"
  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m init
  echo "${dir}"
}

@test "lint targets are the tracked hook, script and lib shell scripts" {
  local repo
  repo="$(mk_repo)"
  targets "${repo}"
  assert_success
  assert_line ".claude/hooks/a_hook.sh"
  assert_line ".claude/scripts/a-script.sh"
  assert_line ".claude/scripts/lib/a-lib.sh"
}

@test "an untracked script is not a lint target" {
  local repo
  repo="$(mk_repo)"
  echo "echo scratch" > "${repo}/.claude/scripts/fix-oneoff.sh"
  targets "${repo}"
  assert_success
  refute_line ".claude/scripts/fix-oneoff.sh"
}

@test "a tracked non-shell file is not a lint target" {
  local repo
  repo="$(mk_repo)"
  targets "${repo}"
  assert_success
  refute_line ".claude/scripts/NOTES.md"
}

@test "a tracked script deleted in the working tree is not a lint target" {
  # The container lints the live mount, so naming a path git still tracks
  # but the worktree no longer has would fail the gate on a file nobody
  # can fix.
  local repo
  repo="$(mk_repo)"
  rm "${repo}/.claude/scripts/a-script.sh"
  targets "${repo}"
  assert_success
  refute_line ".claude/scripts/a-script.sh"
  assert_line ".claude/hooks/a_hook.sh"
}

@test "t_lint lints the computed target list, not a shell glob" {
  # A glob inside the container is what broke local/CI parity: it sees
  # every file on the mount, tracked or not.
  local body
  body="$(sed -n '/^t_lint()/,/^}/p' "$(ci_sh)")"
  echo "${body}" | grep -q 'lint_targets' \
    || { echo "t_lint does not use lint_targets: ${body}" >&2; return 1; }
  echo "${body}" | grep -q '/work/.claude/scripts/\*\.sh' \
    && { echo "t_lint still passes a glob into the container" >&2; return 1; }
  return 0
}
