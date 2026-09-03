# Integration Tests

Integration level (ISTQB): several hooks / components together. **11 tests**
under `.claude/test/bats/integration/`.

### .claude/test/bats/integration/chain_spec.bats (3)
| Test | Scenario |
|------|----------|
| git commit with Co-Authored-By: Claude AND code-only stage fires both pre-tool hooks | `remind_no_ai_attribution` + `check_changelog_drift` both FIRE on the same input |
| gh pr create with attribution body fires both pre-tool hooks | `remind_ci_auto_merge` + `remind_no_ai_attribution` both FIRE |
| editing a Dockerfile fires only the TDD reminder, not content-scan hooks | `remind_tdd_categories` FIRE; emoji/AI-attribution/coverage-excl SILENT |

### .claude/test/bats/integration/update_stale_pr_autoresolve_spec.bats (8)

| Test | Scenario |
|------|----------|
| count-drift-only merge is auto-resolved, committed and pushed | real merge conflicting only on regenerated figures: resolved, regenerated, committed, pushed |
| auto-resolution reports the file, hunk count and before/after figures | report names the file, the hunk count, both discarded sides and the recomputed value |
| a numeric conflict outside the generator's output set exits 2 | mask-equal hunk in doc/metrics.md: ownership, not shape, decides -- exits 2 |
| one prose conflict among many count conflicts resolves nothing, exits 2 | all-or-nothing: exits 2, markers intact, no merge commit, nothing pushed |
| --dry-run classifies an in-progress merge and writes nothing | auto-resolvable verdict printed; markers, HEAD and origin tip all unchanged |
| --dry-run reports the manual verdict without touching the tree | manual verdict, whole-tree classification, nothing written |
| prose differing only in a digit is refused, not silently kept | mask-equal but generator-preserved: exits 2, markers intact, nothing pushed |
| --dry-run refuses a digit-only prose conflict and writes nothing | dry-run verdict matches the live refusal; nothing written |
