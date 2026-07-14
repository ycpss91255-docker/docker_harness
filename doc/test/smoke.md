# Smoke Tests (N/A)

Smoke is an ISTQB *type* (build-verification: "does the product even come
up"), performed at build time inside a product image's `-test` stage.

docker_harness ships **no product image** -- its test image is only a bats
runner, with no devel / runtime product stage to smoke-verify. The Smoke
type is therefore **N/A** here; there are **0** smoke specs by design.

The former `test/smoke/` directory held per-hook isolation tests, which are
Unit-level under ISTQB and now live in [unit.md](unit.md) /
`.claude/test/bats/unit/`.

For the base template's real per-stage smoke templates, see base
`dist/test/bats/smoke/`.
