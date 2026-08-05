Tag and release repos following the project's semantic versioning and RC workflow.

The actual ycpss91255-docker convention is **branch → bump → chore PR → merge
→ tag merge commit**, not "tag main directly". Tags are annotated and applied
on the **merge commit** of a `chore: release vX.Y.Z` PR. RC tags follow the
same flow, just with `-rcN` suffix.

## 1. Determine scope

Parse the argument for both VERSION and TARGET:

- **Version shape**:
  - `MAJOR.MINOR.0` — new feature or behaviour change. RC required.
  - `MAJOR.MINOR.PATCH` — bug fix / doc fix. RC NOT required (see v0.12.1, v0.12.2, v0.12.3).
  - `MAJOR.MINOR.0-rcN` — explicit Release Candidate.
  - User can override via context — if the argument explicitly includes `-rcN`, honour it.

- **Target repo(s)**: named by their workspace path in
  `.claude/scripts/lib/roster.tsv`, the one roster (`env/*`, `agent/*`,
  `app/*` groups; `.claude/scripts/batch-base-upgrade.sh --list-repos`
  prints the active set). `base` is its own target — it carries a
  `.version` line the rest do not. Or specify individual repos.

## 2. Branch + bump

For each target repo, in its working tree:

```bash
git checkout main && git pull --ff-only origin main
git checkout -b release/vX.Y.Z
```

**For the `base` repo**, bump two files:

- `.version` — single line, the new tag.
- `doc/changelog/CHANGELOG.md` — promote the `[Unreleased]` section to
  `[vX.Y.Z] - YYYY-MM-DD` (today's absolute date), insert a fresh empty
  `[Unreleased]` heading above it.

  The promoted section keeps the `### Added / Changed / Fixed / ...` content
  written during PR work — this is why CHANGELOG entries should be added at
  PR-time, not deferred to release.

**For container repos** (env / agent / app), there is no top-level `.version`;
the version is propagated through `.base/.version` via the subtree upgrade.
A release commit on those repos is typically just a CHANGELOG bump (if the
repo has its own CHANGELOG) and possibly a `main.yaml` `@tag` adjustment.

## 3. Open the chore PR

```bash
git add -A && git commit -m "chore: release vX.Y.Z"
git push -u origin release/vX.Y.Z
gh pr create --title "chore: release vX.Y.Z" --body-file <(cat <<'EOF'
## Summary

<one-liner — what's in this release; reference the merged PRs.>

No breaking changes from <previous version>.

## Test plan

- [x] CI green on the PRs being rolled into this release
- [ ] After merge: tag vX.Y.Z and verify release-test-tools.yaml /
      release-worker.yaml run cleanly against the new image / archive
EOF
)
```

## 4. Wait CI green on the chore PR

Use the `wait-pr-ci` skill (PR-scoped flavour):

```
Skill: wait-pr-ci <PR#> <OWNER>/<REPO>
```

Or directly:

```
Monitor: .claude/scripts/wait-pr-ci.sh --repo <OWNER>/<REPO> --prs <PR#>
```

## 5. Merge

```bash
gh pr merge <PR#> --repo <OWNER>/<REPO> --squash --delete-branch
git checkout main && git pull --ff-only origin main
```

The squash-merge SHA is the commit you'll tag in step 6.

## 6. Annotated tag on the merge commit

```bash
.claude/scripts/release-tag.sh vX.Y.Z -m "vX.Y.Z: <one-line summary referencing closed PRs/issues>"
# X bump (vX.0.0) also requires explicit ACK env after user OK in chat:
#   RELEASE_X_BUMP_ACK=vX.0.0 .claude/scripts/release-tag.sh vX.0.0 -m "..."
```

The canonical script enforces (issue #106):

- `.version` integrity (tag literal must equal `.version`).
- RC tag with passing CI for Y bumps (`vX.Y.0`) and X bumps (`vX.0.0`).
- X-bump ACK gate via `RELEASE_X_BUMP_ACK=<exact-tag>` env.
- See `.claude/skills/semver-bump/SKILL.md` for the full workflow.

The hook `enforce_semver_tag_via_script.sh` BLOCKs ad-hoc
`git tag v*` / `git push.*v[0-9]` to force this routing.

For RC tags, use `vX.Y.0-rcN`. RCs are auto-marked as GitHub prereleases
because `release-worker.yaml` checks for `-` in the ref name.

**Commit messages and tag annotations MUST use backticks to wrap `@xxx`
patterns** (e.g., `` `@default:` ``) — bare `@xxx` triggers GitHub
@mention parsing in commit views.

## 7. Wait tag-triggered workflows

Tags fire several workflows in parallel:

- `base`: `Self Test` (with `release` job) + `Release test-tools image to GHCR`
- container repos: `call-docker-build` + `call-release`

Use the `wait-pr-ci` skill's tag flavour:

```
Monitor: .claude/scripts/wait-tag-ci.sh --repo <OWNER>/<REPO> --branch vX.Y.Z
```

This is **not** PR-scoped — `gh pr view` gives nothing for a pushed tag.
The script polls `gh run list --branch vX.Y.Z` instead.

## 8. RC failure handling

If RC CI (step 4) or tag workflows (step 7) fail:

- Open a fix PR against `main` addressing the failure (NOT the release branch).
- Once that fix lands, restart this skill from step 2 with `vX.Y.Z-rcN+1`.
- **Never** re-tag the same RC — `git push origin :vX.Y.0-rc1` then re-pushing
  is destructive on a public tag and confuses release-worker workflows that
  may have already run.

## 9. Downstream propagation (base only)

After tagging `base@vX.Y.Z`:

- Every **active** downstream repo needs its `.base/` subtree pulled to
  the new tag. Which repos those are is not stated here and must not be
  retyped anywhere: `.claude/scripts/lib/roster.tsv` is the one roster,
  and `batch-base-upgrade.sh --list-repos` prints the effective set.
- Use `/batch-base-upgrade vX.Y.Z` to mass-upgrade them in one batch
  (one PR per downstream repo, parallel CI). The command name keeps
  the `template` prefix for backward compatibility with existing scripts
  / muscle memory; it has always upgraded the `.base/` subtree.
- Verify with `.claude/scripts/check-template-versions.sh --expect vX.Y.Z`.
  It reads the SAME roster call, so it covers exactly what the upgrader
  touched and fails (rather than exiting 0 over an empty list) when the
  selection is empty (refs #272).
- This is its own multi-PR workflow — run `/batch-base-upgrade` after
  the base tag's CI is fully green; do not interleave with the release
  itself.

## Important reminders

- Tags are **annotated**: always `-a` + `-m`. Lightweight tags don't carry the message and `release-worker.yaml`'s release-notes extraction breaks on them.
- The CHANGELOG `[Unreleased]` heading must remain above the new release section for the next cycle. Don't delete it.
- Do not `--no-verify` or skip hooks during the chore PR commit. The hook gates (CHANGELOG drift, TEST.md drift, emoji, AI attribution) catch real issues at the worst possible time of the cycle.
- `release-worker.yaml` is not part of the `base` repo's own self-test — it lives in `base` and is consumed by container repos via `uses: ycpss91255-docker/base/.github/workflows/release-worker.yaml@<tag>`. Verify it ran cleanly via step 7.

## Context

Argument from user: $ARGUMENTS

Now execute this workflow.
