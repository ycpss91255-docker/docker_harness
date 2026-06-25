# ADR-00000011: Split Skill Tracking — Repo-Owned Tracked, Vendored Machine-Local

- **Date:** 2026-06-25
- **Status:** Accepted
- **Supersedes:** [ADR-00000010](00000010-vendor-in-mattpocock-skills.md)

## Context

ADR-00000010 (2026-06-11) decided to **vendor-in** the eleven
`mattpocock/skills` third-party skills: commit `.agents/skills/<11>/`,
commit `skills-lock.json`, and commit the eleven
`.claude/skills/<name>` symlinks, so that fresh clones received the
full skill set without running an installer.

Two facts surfaced afterwards that re-open that decision:

1. **The native (repo-owned) skills were never canonicalised.** Nine
   (now ten, after `batch-mutation-pr`) repo-owned skills
   — `batch-mutation-pr`, `gh-artifact-format`, `parallel-agents`,
   `proactive-optimization`, `rebase-pr`, `semver-bump`,
   `skillification-candidates`, `strategic-compact`, `wait-gh-state`,
   `wait-pr-ci` — remained as **real directories under
   `.claude/skills/`**, i.e. Claude-Code-specific. Third-party skills
   already used the agent-agnostic `.agents/skills/<name>/` + symlink
   layout, so the canonical store was split by *ownership* in the
   wrong axis: third-party was agent-agnostic, repo-owned was not. A
   future non-Claude agent (Gemini CLI, etc.) could not share the
   repo-owned skills. Issue #210 asks to fix this.

2. **The vendored skills have a clean, first-class reinstaller.** They
   are installed with `npx skills@latest add mattpocock/skills`
   (upstream <https://github.com/mattpocock/skills>). Committing their
   content into *this* repo means carrying a second copy of upstream
   source that drifts from upstream and bloats history, when a one-line
   command reconstructs it on any machine. ADR-10's premise — "fresh
   clones need the skills without a setup step" — does not hold for a
   repo whose own purpose is to *manage* agent configuration: the
   agent config this repo owns is its hooks, commands, scripts, and the
   ten **repo-owned** skills; the vendored skills are an external
   dependency, tracked the way a lockfile tracks dependencies, not by
   committing the dependency itself.

## Decision

Split skill tracking by **ownership**, and make the canonical store
uniform across both kinds:

- **Repo-owned skills (10): tracked.** Canonical content lives under
  `.agents/skills/<name>/` (real directory, `git mv`'d from
  `.claude/skills/<name>` so history is preserved), surfaced to Claude
  Code via a tracked symlink `.claude/skills/<name>` →
  `../../.agents/skills/<name>`. Both ends are committed.
- **Third-party (mattpocock) skills: NOT tracked.** `.agents/skills/`
  and `.claude/skills/` are ignored at the contents level
  (`.agents/*` + `!.agents/skills/` + `.agents/skills/*`;
  `.claude/skills/*`) with the ten repo-owned skills negated back in at
  both ends. `git cannot re-include a path once its parent dir is
  ignored`, hence the layer-by-layer form. The eleven previously-
  committed vendored dirs, their eleven symlinks, and
  `skills-lock.json` are removed from the index (`git rm --cached`,
  content left on disk) and become machine-local.
- **Reinstall path:** `npx skills@latest add mattpocock/skills`.
  Documented in `README.md` so a fresh clone knows the vendored skills
  must be installed to gain their functionality.
- **`skills-lock.json` is no longer tracked.** It is install state
  managed by the `skills` CLI; with `@latest` the workflow does not pin
  versions, so a committed lock added no guarantee this model needs.

A bats invariant (`skills_canonical_layout_spec.bats`) asserts the ten
repo-owned skills are symlinks resolving into a real
`.agents/skills/<name>/` canonical dir, so an accidental revert to a
real `.claude/skills/` directory (or a broken symlink) fails CI.

## Consequences

**Good:**

- The canonical store is uniform: every skill — repo-owned or vendored
  — lives under `.agents/skills/<name>/` with a `.claude/skills/`
  symlink. Repo-owned skills are now agent-agnostic and shareable by a
  future non-Claude agent.
- This repo tracks exactly what it owns; the upstream dependency is no
  longer duplicated in git history.
- `make -C .claude/test check` enforces the layout via the new spec.

**Bad / risks:**

- A fresh clone has the ten repo-owned skills immediately but must run
  `npx skills@latest add mattpocock/skills` to recover the vendored
  ones. CI is unaffected (it does not consume skills); the cost falls
  only on first interactive/agent use. README documents this.
- Reference paths citing `.claude/skills/<name>/SKILL.md` keep working
  unchanged — symlink resolution is transparent.

**Reversal cost:** low. The vendored content remains recoverable from
upstream via the installer; re-tracking would be a `git add` + lockfile
re-commit.

## References

- Issue ycpss91255-docker/docker_harness#210
- ADR-00000010 (superseded — the vendor-in decision this reverses for
  the third-party half)
- `npx skills@latest add mattpocock/skills` /
  <https://github.com/mattpocock/skills> (upstream + reinstaller)
- `.claude/hooks/test/smoke/skills_canonical_layout_spec.bats` (the
  layout invariant)
