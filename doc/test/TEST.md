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

Grand total (all levels): **1084 tests**.

## Test docs by level / type

| Doc | Scope | Count |
|-----|-------|-------|
| [unit.md](unit.md) | `.claude/test/bats/unit/` -- one hook / script in isolation | 1076 |
| [integration.md](integration.md) | `.claude/test/bats/integration/` -- several hooks on one input | 3 |
| [system.md](system.md) | `.claude/test/bats/system/` -- whole framework passes its own gates | 3 |
| [acceptance.md](acceptance.md) | `.claude/test/bats/acceptance/` -- what a consumer session receives | 2 |
| [smoke.md](smoke.md) | N/A -- no product image build stage | 0 |

## Static analysis

`just -f .claude/test/justfile lint` runs `shellcheck` on every top-level
`.sh` in `.claude/hooks/` and `.claude/scripts/` (42 hooks + 37 helper
scripts); `... hadolint` lints `.claude/test/Dockerfile`. The full gate
`... check` also runs the repo-integrity audits (tree / ceiling /
log-helper) that the System specs mirror. CI runs the same
`.claude/test/ci.sh <target>` driver.
