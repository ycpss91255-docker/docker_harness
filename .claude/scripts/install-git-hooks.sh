#!/usr/bin/env bash
# log-allow:script -- the chain notice is a next-step hint read by a human; the script is copied into repos without lib/log.sh.
# install-git-hooks.sh -- make every commit in this checkout run the tracked
# .claude/githooks/commit-msg hook, which refuses AI attribution markers
# (refs base#1988). Run it from the repo root.
#
# With no active hook in the hooks dir (an executable that is not a
# *.sample), core.hooksPath is pointed at .claude/githooks. Otherwise
# setting core.hooksPath would stop git running those hooks, so the tracked
# commit-msg is linked into the hooks dir instead; an existing commit-msg is
# never touched, and the script prints how to chain the tracked hook from it.

set -euo pipefail

tracked=".claude/githooks"
[[ "$(git config --get core.hooksPath || true)" == "${tracked}" ]] && exit 0

dir="$(git rev-parse --git-path hooks)"
hook="${dir}/commit-msg"
target="$(git rev-parse --show-toplevel)/${tracked}/commit-msg"
[[ "$(readlink "${hook}" || true)" == "${target}" ]] && exit 0
active=()
for f in "${dir}"/*; do
  [[ -f "${f}" && -x "${f}" && "${f}" != *.sample ]] && active+=("${f##*/}")
done
if (( ${#active[@]} == 0 )); then
  git config core.hooksPath "${tracked}"
elif [[ ! -e "${hook}" && ! -L "${hook}" ]]; then
  ln -s "${target}" "${hook}"
  printf 'install-git-hooks: active git hooks already exist in %s (%s); linked %s to %s instead of setting core.hooksPath.\n' \
    "${dir}" "${active[*]}" "${hook}" "${target}"
else
  # shellcheck disable=SC2016  # "$1" is the literal line to paste into the hook
  printf 'install-git-hooks: %s already exists; left it and core.hooksPath unchanged. To chain, add this line to it and keep it executable (chmod +x %s): %s/commit-msg "$1" || exit 1\n' \
    "${hook}" "${hook}" "${tracked}"
fi
