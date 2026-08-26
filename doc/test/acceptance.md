# Acceptance Tests

Acceptance level (ISTQB, UAT/OAT): what a consumer session receives when it
loads this `.claude/` framework. **3 tests** under
`.claude/test/bats/acceptance/`.

Not a hook's internal logic (that is unit) but the delivered whole hanging
together: registered hooks resolve to real scripts, skill symlinks point at
real `SKILL.md` files. A rename that updates a hook but forgets
`settings.json`, or a skill move that dangles a symlink, is a
consumer-facing breakage no unit spec catches.

### .claude/test/bats/acceptance/framework_integrity_spec.bats (3)
| Test | Scenario |
|------|----------|
| acceptance: every settings.json-registered hook command resolves to a file | no dangling hook registration |
| acceptance: every .claude/skills symlink resolves to a SKILL.md | no dangling skill symlink |
| acceptance: every enforce_*.sh hook is armed in settings.json | - |
