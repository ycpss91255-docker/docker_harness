#!/usr/bin/env bash
# enforce_rm_outside_git_tree.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# RED placeholder. The property this hook must compute (refs #290):
#
#   A deletion whose RESOLVED TARGET is inside a git working tree needs a
#   human; a deletion anywhere else does not.
#
# This stub decides nothing, which is what the mechanism it replaces does for
# every spelling that walked past it. Each stanza in
# .claude/test/bats/unit/enforce_rm_outside_git_tree_spec.bats that expects an
# allow or a deny therefore fails here, and fails for the reason it names
# (empty output where a permissionDecision was expected) rather than because
# the hook file does not exist.

set -uo pipefail

main() {
  local input
  input="$(cat)"
  : "${input}"
  return 0
}

main "$@"
