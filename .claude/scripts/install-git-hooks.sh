#!/usr/bin/env bash
# log-allow:script -- the chain notice is a next-step hint read by a human; the script is copied into repos without lib/log.sh.
# install-git-hooks.sh -- point this checkout's core.hooksPath at the tracked
# .claude/githooks dir, so the commit-msg hook refuses AI attribution markers
# on every commit (refs base#1988). Run it from the repo root.
#
# An active commit-msg hook already in the hooks dir is left alone: setting
# core.hooksPath would stop git running it, so the script prints how to chain
# the tracked hook from it instead and exits 0.

set -euo pipefail

tracked=".claude/githooks"
if [[ "$(git config --get core.hooksPath || true)" != "${tracked}" ]]; then
  existing="$(git rev-parse --git-path hooks)/commit-msg"
  if [[ -x "${existing}" ]]; then
    # shellcheck disable=SC2016  # "$1" is the literal line to paste into the hook
    printf 'install-git-hooks: an active commit-msg hook already exists at %s; left it in place. To chain, add this line to it: %s/commit-msg "$1" || exit 1\n' \
      "${existing}" "${tracked}"
    exit 0
  fi
fi

git config core.hooksPath "${tracked}"
