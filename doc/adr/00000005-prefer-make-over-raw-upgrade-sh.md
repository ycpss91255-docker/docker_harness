# ADR-00000005: `make -f Makefile.ci upgrade` is Canonical; `./.base/upgrade.sh` is Fallback

- **Date:** 2026-05-20
- **Status:** Superseded by ADR-00000011 / issue #280 (2026-08-26)

> **Superseded.** `make` is retired fleet-wide: no repo carries a root
> `Makefile.ci`, and `enforce_wrapper_first_upgrade.sh` no longer treats
> one as a wrapper. The canonical route is now `just upgrade [vX.Y.Z]`
> from the downstream repo's root justfile; `./.base/upgrade.sh` remains
> the ack-gated fallback. The reasoning below is kept as the record of
> why a wrapper-first rule exists at all -- that part still holds.

## Context

Each downstream repo carries `.base/` as a git subtree pulled
from `ycpss91255-docker/base`. Upgrading that subtree to a new
tag (e.g. `vX.Y.Z`) is the most common cross-repo operation:
when the base ships a new release, all downstream repos need to
pull it and run two follow-up fix-ups (init.sh symlink resync
and `main.yaml` `@tag` sed). The raw subtree merge alone is not
sufficient — the two follow-ups are easy to forget, and forgetting
them produces silent breakage:

- **Missing init.sh resync** leaves stale symlinks (`build.sh`,
  `run.sh`, etc.) pointing at script paths that may have moved in
  the new tag. Repo appears upgraded but `./build.sh` is still
  the old version.
- **Missing `main.yaml` `@tag` sed** leaves the reusable-workflow
  reference pinned to the old `@tag`. CI continues to build
  against the previous version's reusable workflow, so changes
  in the new release's CI scaffolding don't take effect.

`./.base/upgrade.sh` performs all three steps (subtree pull +
init.sh resync + main.yaml sed) when invoked correctly, but it's
positional — `./.base/upgrade.sh vX.Y.Z` — and easy to mis-type
(e.g. forget the `v` prefix, hit the wrong working directory).

Issue #36 was the trigger: `template v0.18.0` / `v0.18.1` shipped
with `.version` files that downstream repos did not pick up
because someone ran `git subtree pull` directly instead of
`./.base/upgrade.sh`. The `make upgrade-check` target then
permanently reported "upgrade available" because `.base/.version`
wasn't in sync with the actual subtree tree state.

## Decision

`make -f Makefile.ci upgrade VERSION=vX.Y.Z` is the canonical
upgrade entry point. `./.base/upgrade.sh vX.Y.Z` is a fallback,
used only when `make` is unavailable or a `Makefile.ci` target
is broken.

The `make upgrade` target's value-add over the raw script:

- **Named-argument syntax**: `VERSION=vX.Y.Z` is harder to
  mis-type than positional `./.base/upgrade.sh vX.Y.Z`. The
  Make rule validates the variable's format before invoking.
- **Wraps `upgrade-check` + `upgrade` consistently**: the make
  target chains `upgrade-check` first, so users see a "no new
  version" message instead of running a no-op merge.
- **Makefile is discoverable**: `make -f Makefile.ci help` lists
  every target with its description. The bare script has only
  `--help`, which contributors are less likely to find.

Enforcement: PreToolUse hook `remind_make_first_upgrade.sh`
fires when an agent runs `./.base/upgrade.sh` directly,
suggesting the make wrapper.

`./.base/upgrade.sh` is not removed — it's the implementation
the make rule calls, and the fallback when `make` is missing
(e.g. minimal CI runner image).

## Alternatives

Three alternatives were considered and rejected:

1. **Delete `./.base/upgrade.sh`, keep only the make target.**
   Rejected: not every consumer has GNU make available
   (Alpine-based minimal images, Windows users in PowerShell,
   etc.). The shell script must keep existing as the actual
   implementation; the make target is the wrapper.

2. **Keep both equally documented, no preference.** Rejected:
   the absence of a canonical path is exactly what caused
   issue #36. Without a "prefer X over Y" convention, half the
   contributors pick one and half the other; the half that
   picks the raw script periodically misses the follow-ups
   and ships broken upgrades.

3. **Add the init.sh + main.yaml fix-ups as a separate
   `make post-upgrade` target users invoke manually.**
   Rejected: the post-upgrade steps are not optional — they're
   required for the upgrade to be correct. Splitting them off
   creates yet another step contributors can forget.

## Consequences

- **Documented entry point in every flow**: CLAUDE.md "subtree
  update flow" lists `make upgrade` first, `./.base/upgrade.sh`
  second with "fallback only" annotation.

- **Hook nudges in real time**: agents directly invoking
  `./.base/upgrade.sh` get a hook reminder. Hook is
  non-blocking (informational), so the fallback path stays open
  when needed.

- **CI / batch scripts use the make form**: `batch-template-
  upgrade.sh` invokes `make upgrade` per repo, not the raw
  script. Future batch scripts adopt the same convention.

- **`Makefile.ci` is in scope of every change to upgrade
  behaviour**: changes to upgrade flow must update both the
  script (implementation) and the make target (interface). The
  make target's `help:` text is the contract contributors read.

## References

- Issue ycpss91255-docker/docker_harness#119 (this ADR's
  tracking issue; Tier 1 of #116).
- Issue ycpss91255-docker/docker_harness#36 (the
  `template v0.18.x` incident that motivated this convention).
- `.claude/hooks/remind_make_first_upgrade.sh` — the enforcing
  hook.
- `.base/Makefile.ci` `upgrade` target — the canonical entry.
- `.base/upgrade.sh` — the implementation.
