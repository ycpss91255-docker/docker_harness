# ADR-00000010: Vendor-In Matt Pocock Skills Installer State

- **Date:** 2026-06-11
- **Status:** Accepted

## Context

For several months the project's `.claude/skills/` directory has
carried two distinct kinds of skill artifacts:

1. **Native** skills written for this repository's domain glossary
   and tracked normally in git (e.g. `wait-pr-ci`, `rebase-pr`,
   `semver-bump`, `gh-artifact-format`, `strategic-compact`,
   `parallel-agents`, `proactive-optimization`,
   `skillification-candidates`, `wait-gh-state`). Nine in total.
2. **Vendored** skills from `mattpocock/skills` (an upstream skill
   library), installed locally by an installer that places real
   content under `.agents/skills/<name>/`, records a lock entry
   per skill in `skills-lock.json` (source repo + skillPath +
   computedHash), and creates a symlink at
   `.claude/skills/<name>` → `../../.agents/skills/<name>`.
   Fourteen in total at the time of writing
   (caveman / diagnose / grill-me / grill-with-docs / handoff /
   improve-codebase-architecture / prototype /
   setup-matt-pocock-skills / tdd / to-issues / to-prd / triage /
   write-a-skill / zoom-out).

Before this ADR the vendored half was **not tracked in git** —
neither `.agents/skills/`, nor `skills-lock.json`, nor the
symlinks at `.claude/skills/<name>` were committed. Fresh clones
and new machines received only the nine native skills. A user
needed to remember to run the installer to recover the other
fourteen, and any drift between machines (different installer
runs at different times, different lock content) was invisible.

Issue #185 grilled the right action. Three real options
surfaced:

- **(A) Adopt all 14**: commit `.agents/skills/` + lock + symlinks.
  Fresh clones inherit the full skill set, no setup step.
- **(B) Remove all 14**: drop the cluster, lose `/grill-me`,
  `/tdd`, `/handoff`, `/diagnose`, `/prototype`,
  `/improve-codebase-architecture`, `/to-issues`,
  `/write-a-skill`, `/zoom-out`, `/caveman`, `/grill-with-docs`.
- **(C) Split**: keep the generic agent-tool skills, drop the
  three skills that hard-depend on a Matt-Pocock-specific 5-role
  triage label vocabulary (`to-prd`, `triage`,
  `setup-matt-pocock-skills`) which this repository does not use.

The session that produced this ADR (2026-06-08 → 2026-06-11) had
already exercised four of the vendored skills (`/grill-me`,
`/to-issues`, `/tdd`, and implicitly the others via the skill
list). Their value was concrete, not speculative.

## Decision

Adopt path **(C) Split**. Commit:

- `.agents/skills/<11>/` — 11 full skill directories: `caveman`,
  `diagnose`, `grill-me`, `grill-with-docs`, `handoff`,
  `improve-codebase-architecture`, `prototype`, `tdd`,
  `to-issues`, `write-a-skill`, `zoom-out`.
- `skills-lock.json` — restricted to 11 entries (the three Matt
  Pocock cluster entries `to-prd`, `triage`,
  `setup-matt-pocock-skills` are removed).
- `.claude/skills/<11>` — 11 symlinks pointing at the vendored
  copies.

The three excluded skills are deleted from the local working tree
along with their lock entries and symlinks.

One in-flight edit to `to-issues/SKILL.md`: remove the line
"`The issue tracker and triage label vocabulary should have been
provided to you — run /setup-matt-pocock-skills if not.`" because
the referenced skill is going away. `skills-lock.json`'s
`computedHash` for `to-issues` is recomputed against the edited
content so the installer detects no drift.

Two other in-flight edits proposed during the grill
(`grill-with-docs` `docs/adr` → `doc/adr` and
`improve-codebase-architecture` subagent guidance) were
**re-examined and dropped**:

- `grill-with-docs` references `docs/adr/` only as an example
  directory structure illustrating skill semantics; the skill
  itself is path-agnostic and runs fine in repos that use
  `doc/adr/`.
- `improve-codebase-architecture`'s `subagent_type=Explore`
  guidance applies to read-only exploration, which the
  `feedback_subagent_sandbox_limits` memory explicitly allows —
  the memory's stricter rule is about mutation paths only.

Both edits would have introduced unnecessary divergence from
upstream `mattpocock/skills`. Skipping them keeps the
vendor-in 1:1 with upstream except for the single `to-issues`
edit, which is justified by the cluster-removal decision.

## Consequences

**Good:**

- Fresh clones receive the full skill set out of the box. No
  installer step required.
- `skills-lock.json` continues to work as the upstream drift
  detector — `computedHash` will mismatch when upstream
  `mattpocock/skills` updates a skill, prompting an explicit
  upgrade decision via the installer.
- `CLAUDE.md` Workflows table now references all 10 adopted
  skills (the 11th, `tdd`, was already listed).
- Memory entries that reference adopted skills
  (`feedback_tdd_skill_invocation`) keep working without
  modification.

**Bad / risks:**

- Repository size grows by the on-disk size of the 11 vendored
  skill directories. Measured: a few hundred KB across 11
  dirs — negligible.
- Edits to vendored content (currently only the `to-issues` line)
  must keep `computedHash` in sync; future maintainers need to
  understand the lock-file contract before editing.
- Upstream `mattpocock/skills` changes need to be pulled
  manually via the installer; nothing auto-syncs.

**Reversal cost:** medium. Reverting means rm'ing the 11 vendored
dirs + lock entries + symlinks + CLAUDE.md rows. Mechanical, not
destructive — the upstream `mattpocock/skills` repo remains the
recoverable source.

## References

- Issue ycpss91255-docker/docker_harness#185
- `skills-lock.json` (now committed; the upstream drift contract)
- `mattpocock/skills` (upstream)
- ADR-00000003 (CONTEXT.md single-file decision — same flavour of
  "single source of truth over scattered metadata")
