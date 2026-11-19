#!/usr/bin/env bash
# install-git-hooks.sh -- point this checkout's core.hooksPath at the tracked
# .claude/githooks dir, so the commit-msg hook refuses AI attribution markers
# on every commit (refs base#1988). Run it from the repo root.

set -euo pipefail

git config core.hooksPath .claude/githooks
