# Tests

Index of the docker_harness self-test suite. The taxonomy is ISTQB-aligned
(ADR-00000013): the **levels** are Unit -> Integration -> System ->
Acceptance, plus **static analysis** (lint). **Smoke** is a
build-verification *type*; docker_harness ships no product image, so it is
N/A here (see [smoke.md](smoke.md)). Per-level spec catalogs (each carrying
its own `@test` counts) live in the sibling docs below.

All tests run inside Docker via the `.claude/test/Dockerfile` image:

```bash
just -f .claude/test/justfile test     # run all bats specs
just -f .claude/test/justfile check    # lint + hadolint + test + audits (full gate)
```

The `justfile` recipes are the local wrapper; CI
(`.github/workflows/test.yaml`) invokes the same `.claude/test/ci.sh
<target>` driver directly (no `just` in CI).

Grand total (all levels): **1177 tests**.

## Test docs by level / type

| Doc | Scope | Count |
|-----|-------|-------|
| [unit.md](unit.md) | `.claude/test/bats/unit/` -- one hook / script in isolation | 1167 |
| [integration.md](integration.md) | `.claude/test/bats/integration/` -- several hooks on one input | 3 |
| [system.md](system.md) | `.claude/test/bats/system/` -- whole framework passes its own gates | 4 |
| [acceptance.md](acceptance.md) | `.claude/test/bats/acceptance/` -- what a consumer session receives | 3 |
| [smoke.md](smoke.md) | N/A -- no product image build stage | 0 |

## Generated, not hand-maintained

Every figure in these docs is derived from the spec tree by
`.claude/scripts/sync-doc-test-counts.sh`: the per-spec `### <path> (N)`
headings, the per-test catalogue rows, the per-level `**N tests**` totals,
and this file's grand total plus index table. Run it after touching a spec:

```bash
.claude/scripts/sync-doc-test-counts.sh          # regenerate
just -f .claude/test/justfile doc-count-check    # read-only gate (CI runs it too)
```

A hand-written description in a `| Test | Scenario |` row survives
regeneration -- rows are keyed on the test name. A deleted test loses its
row, a deleted spec loses its whole section, and a renamed test arrives as a
new row with a `-` placeholder (rename the row in the doc first if you want
to carry the prose across). Row order follows the spec file, so reordering a
spec produces a matching doc diff. Full contract: the script's header.

## Static analysis

`just -f .claude/test/justfile lint` runs `shellcheck` on every top-level
`.sh` in `.claude/hooks/` and `.claude/scripts/`
(44 hooks + 39 helper scripts); `... hadolint` lints
`.claude/test/Dockerfile`. The full gate
`... check` also runs the repo-integrity audits (tree / ceiling /
log-helper) that the System specs mirror. CI runs the same
`.claude/test/ci.sh <target>` driver.
