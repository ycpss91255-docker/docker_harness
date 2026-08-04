# System Tests

System level (ISTQB): the whole delivered framework, end-to-end.
**4 tests** under `.claude/test/bats/system/`.

These assert the ACTUAL docker_harness repo passes its own structural
gates -- the same audits the `ci.sh` tree-check / ceiling-check /
log-helper-check targets run, brought into the bats suite so real drift (a
script with no CONTEXT.md tree entry, a CLAUDE.md over its ceiling, a
helper bypassing `lib/log.sh`) surfaces as a system regression. Distinct
from the unit specs, which exercise those audit scripts against synthetic
fixtures.

### .claude/test/bats/system/repo_self_audit_spec.bats (4)
| Test | Scenario |
|------|----------|
| system: CONTEXT.md .claude/ tree aligns with the real filesystem | tree audit against the live repo |
| system: CLAUDE.md stays within its line / section ceilings | ceiling audit against the live repo |
| system: .claude/scripts adopt the lib/log.sh helper | log-helper audit against the live repo |
| system: doc/test catalogs match the real spec tree | doc-count audit against the live repo |
