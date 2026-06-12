#!/usr/bin/env bats

# Covers .claude/scripts/batch-mutation-pr.sh (refs #169) — the generic
# cross-repo fanout engine. Tests the deterministic surface (arg
# validation + --dry-run plan); real worktree/push/PR is not exercised
# here (mirrors batch_gitignore_add_line_spec.bats).

load '../lib/test_helper'

setup() {
  TMP="$(mktemp -d)"
  MUT="${TMP}/mutate.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${MUT}"
  chmod +x "${MUT}"
}

teardown() {
  rm -rf "${TMP}"
}

@test "--help prints usage and exits 0" {
  run "$(script batch-mutation-pr.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--mutation"
  assert_output --partial "--pr-title"
  assert_output --partial "--dry-run"
}
