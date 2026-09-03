# Integration Tests

Integration level (ISTQB): several hooks / components together. **7 tests**
under `.claude/test/bats/integration/`.

### .claude/test/bats/integration/chain_spec.bats (3)
| Test | Scenario |
|------|----------|
| git commit with Co-Authored-By: Claude AND code-only stage fires both pre-tool hooks | `remind_no_ai_attribution` + `check_changelog_drift` both FIRE on the same input |
| gh pr create with attribution body fires both pre-tool hooks | `remind_ci_auto_merge` + `remind_no_ai_attribution` both FIRE |
| editing a Dockerfile fires only the TDD reminder, not content-scan hooks | `remind_tdd_categories` FIRE; emoji/AI-attribution/coverage-excl SILENT |

### .claude/test/bats/integration/ready_for_agent_gates_spec.bats (4)

| Test | Scenario |
|------|----------|
| both gates refuse the same under-specified issue | - |
| both gates accept the same complete issue | - |
| both gates accept parts that arrived as a grill comment | - |
| only Gate A depends on the label being defined in the repo | - |
