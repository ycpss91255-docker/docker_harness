# ADR-00000013: ISTQB-aligned test taxonomy (levels / types / static analysis)

- **Date:** 2026-07-09
- **Status:** Accepted
- **Relates to:** base ADR-00000018 (the same taxonomy on the base /
  dist side), issue #237 (this decision + the docker_harness rollout)

## Context

The test taxonomy was self-defined and mixed incompatible axes. The
"4-category" matrix (CONTEXT.md §11 / `doc/test/TEST.md`) was **Smoke /
Unit / Integration / Lint**, which conflates three different things: Unit
and Integration are *levels* (scope), Smoke is a *type* (purpose), and
Lint is *static analysis* (not a dynamic test at all). base carried the
same confusion plus a non-standard `behavioural` category.

For docker_harness specifically the mismatch was concrete: its bats
suite lived at `.claude/hooks/test/{smoke,integration}/`, and the
`smoke/` directory did not hold Smoke-*type* tests at all -- each spec
drives a single hook in isolation, which is the **Unit** level. The old
matrix even documented "Unit: n/a (hooks are linear single-function
scripts); Smoke covers what unit would", i.e. Smoke was mislabelled and
doing Unit's job. There was also no home for System or Acceptance, and
`test/` was nested under `hooks/` (a misnomer, since the suite also
tests `.claude/scripts/`).

## Decision

Adopt the same ISTQB-aligned three-axis model base uses (ADR-00000018),
kept lightweight: the spine of levels, the few types actually used, and
static analysis.

- **Axis 1 -- Static analysis:** ShellCheck (`.sh`) + Hadolint
  (Dockerfile). Not a dynamic level; run via `ci.sh lint` / `hadolint`.
- **Axis 2 -- Levels:** Unit -> Integration -> System -> Acceptance.
- **Axis 3 -- Types:** Smoke (build-verification), End-to-end,
  Regression -- applied at a level, not levels themselves.

### docker_harness rollout

- The bats suite moves out of `.claude/hooks/test/` into
  `.claude/test/bats/{unit,integration,system,acceptance}/`, co-located
  with the harness (`.claude/test/` is docker_harness's analog of base's
  repo-root `test/`). The former `smoke/` specs are Unit; `chain_spec`
  is Integration.
- Every level carries real content, not reserved dirs: System asserts
  the delivered framework passes its own structural audits (tree /
  ceiling / log-helper) end-to-end; Acceptance asserts what a consumer
  session receives hangs together (every registered hook resolves, every
  skill symlink is live).
- **Smoke is N/A here.** docker_harness ships no product image, so there
  is no `-test` build stage to smoke-verify. There is no
  `.claude/test/bats/smoke/` directory; `doc/test/smoke.md` records why.
  This mirrors base, whose realized `test/bats/` also has no `smoke/`
  (base's smoke templates ship under `dist/test/bats/smoke/`).
- `doc/test/` becomes an index (`TEST.md`) plus per-level catalogs
  (`unit.md` / `integration.md` / `system.md` / `acceptance.md` /
  `smoke.md`), mirroring base's `#695` split.
- The `remind_tdd_categories.sh` hook speaks the three axes and detects
  `test/bats/<level>/`; `check_readme_framework.sh` guidance points at
  the `## Tests` README heading (base's actual framework), retiring the
  old `## Smoke Tests` reference.

## Consequences

- The vocabulary now matches base and the industry standard; "Smoke as a
  level" and the `test/` misnomer under `hooks/` are gone.
- docker_harness has a genuine four-level pyramid (Unit-heavy base ->
  Integration -> System -> Acceptance), so consumer-facing breakages
  (a dangling hook registration, a stale skill symlink, framework drift)
  are now guarded by tests, not just by review.
- The docker_harness ADR number is independent of base's; this is
  ADR-00000013 here and ADR-00000018 there for the same decision.
