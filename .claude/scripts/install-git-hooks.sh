#!/usr/bin/env bash
# log-allow:script -- the chain notice is a next-step hint read by a human; the script is copied into repos without lib/log.sh.
# install-git-hooks.sh -- point this checkout's core.hooksPath at the tracked
# .claude/githooks dir, so the commit-msg hook refuses AI attribution markers
# on every commit (refs base#1988). Run it from the repo root.
#
# Any active hook already in the hooks dir (an executable that is not a
# *.sample) is left alone: setting core.hooksPath would stop git running it,
# so the script prints how to chain the tracked hook from commit-msg instead
# and exits 0.

set -euo pipefail

tracked=".claude/githooks"
[[ "$(git config --get core.hooksPath || true)" == "${tracked}" ]] && exit 0

dir="$(git rev-parse --git-path hooks)"
active=()
for f in "${dir}"/*; do
  [[ -f "${f}" && -x "${f}" && "${f}" != *.sample ]] && active+=("${f##*/}")
done
if (( ${#active[@]} > 0 )); then
  # shellcheck disable=SC2016  # "$1" is the literal line to paste into the hook
  printf 'install-git-hooks: active git hooks already exist in %s (%s); left core.hooksPath unchanged. To chain, add this line to %s/commit-msg (start a new file with #!/bin/sh): %s/commit-msg "$1" || exit 1\n' \
    "${dir}" "${active[*]}" "${dir}" "${tracked}"
  exit 0
fi

git config core.hooksPath "${tracked}"
