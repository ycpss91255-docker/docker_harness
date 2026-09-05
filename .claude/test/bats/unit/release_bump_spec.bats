#!/usr/bin/env bats

# Covers .claude/scripts/release-bump.sh -- the canonical primitive for the
# release BUMP, sibling to release-tag.sh's canonical primitive for the release
# TAG (refs #272).
#
# `release.md` step 2 was prose telling a human to do three mechanical edits by
# hand: set `.version`, promote `## [Unreleased]` to `## [vX.Y.Z] - <today>`,
# re-insert a fresh `[Unreleased]`. It had been done by hand 106 times, and the
# fourth edit -- the Keep-a-Changelog compare link -- had simply stopped
# happening: base's CHANGELOG carries 16 link definitions for 106 version
# headings, so ~90 headings render as dangling references, and the 16 that do
# exist still point at `github.com/ycpss91255-docker/template`, the pre-rename
# URL. That is the signature of a hand-run step: the part nobody notices
# missing stops happening and never comes back.
#
# So the link block is DERIVED from the heading list and the repo's own remote
# on every run, never appended to. Regenerating is what makes the 90-heading
# backfill a single command instead of 90 hand edits, and what stops the block
# lagging again.

load '../lib/test_helper'

setup() {
  REPO="$(mktemp -d)"
  git -C "${REPO}" init -q -b main
  git -C "${REPO}" config user.email t@t
  git -C "${REPO}" config user.name t
  git -C "${REPO}" remote add origin https://github.com/ycpss91255-docker/base.git
  mkdir -p "${REPO}/doc/changelog"
  echo 'v0.6.8' > "${REPO}/.version"
  CL="${REPO}/doc/changelog/CHANGELOG.md"
}

teardown() {
  rm -rf "${REPO}"
}

# seed_changelog -- a changelog shaped like base's: several releases, a link
# block that stopped short and still names the pre-rename repo.
seed_changelog() {
  {
    printf '# Changelog\n\n'
    printf 'The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).\n\n'
    printf '## [Unreleased]\n\n'
    printf '### Fixed\n- something\n\n'
    printf '## [v0.6.8] - 2026-04-20\n\n### Added\n- eight\n\n'
    printf '## [v0.6.7] - 2026-04-19\n\n### Added\n- seven\n\n'
    printf '## [v0.6.6] - 2026-04-18\n\n### Added\n- six\n\n'
    printf '[v0.6.6]: https://github.com/ycpss91255-docker/template/compare/v0.6.5...v0.6.6\n'
  } > "${CL}"
}

bump() { "$(script release-bump.sh)" "$@"; }

@test "--help prints usage and exits 0" {
  run bump --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--links-only"
  assert_output --partial "--check"
}

@test "invalid tag shape exits 2" {
  seed_changelog
  run bump 0.6.9 --repo-root "${REPO}"
  assert_failure 2
  assert_output --partial 'tag shape'
}

@test "bumps .version to the tag literal" {
  seed_changelog
  run bump v0.6.9 --repo-root "${REPO}" --date 2026-04-21
  assert_success
  assert_equal "$(cat "${REPO}/.version")" 'v0.6.9'
}

@test "promotes Unreleased and re-inserts an empty one above it" {
  seed_changelog
  run bump v0.6.9 --repo-root "${REPO}" --date 2026-04-21
  assert_success
  run grep -n '^## \[' "${CL}"
  assert_line --index 0 --partial '## [Unreleased]'
  assert_line --index 1 --partial '## [v0.6.9] - 2026-04-21'
  # The section content stays with the release it was written for.
  run bash -c "awk '/^## \[v0.6.9\]/{f=1;next} /^## \[/{f=0} f' '${CL}'"
  assert_output --partial '- something'
}

@test "every version heading gets a compare link, oldest anchored at the tag" {
  seed_changelog
  run bump v0.6.9 --repo-root "${REPO}" --date 2026-04-21
  assert_success
  local body
  body="$(cat "${CL}")"
  local h
  for h in v0.6.9 v0.6.8 v0.6.7 v0.6.6; do
    grep -qE "^\[${h}\]: https://github.com/ycpss91255-docker/base/(compare|releases)" <<< "${body}" \
      || fail "heading ${h} has no link definition:
${body}"
  done
  grep -qxF '[v0.6.7]: https://github.com/ycpss91255-docker/base/compare/v0.6.6...v0.6.7' <<< "${body}" \
    || fail "compare link is not previous...this"
  grep -qxF '[v0.6.6]: https://github.com/ycpss91255-docker/base/releases/tag/v0.6.6' <<< "${body}" \
    || fail "the oldest heading must anchor at its release tag, not a compare"
  grep -qxF '[Unreleased]: https://github.com/ycpss91255-docker/base/compare/v0.6.9...HEAD' <<< "${body}" \
    || fail "Unreleased must compare the newest release against HEAD"
}

@test "regenerating rewrites links that point at the pre-rename repo" {
  # The 16 surviving definitions in base still say .../template/compare/...
  # Derivation from the remote is what fixes all of them at once.
  seed_changelog
  run bump --links-only --repo-root "${REPO}"
  assert_success
  run grep -c 'ycpss91255-docker/template' "${CL}"
  assert_output '0'
}

@test "--links-only backfills without touching .version or the headings" {
  seed_changelog
  local before_headings
  before_headings="$(grep -c '^## \[' "${CL}")"
  run bump --links-only --repo-root "${REPO}"
  assert_success
  assert_equal "$(cat "${REPO}/.version")" 'v0.6.8'
  assert_equal "$(grep -c '^## \[' "${CL}")" "${before_headings}"
  run grep -c '^\[v\?[0-9]' "${CL}"
  assert_output '3'
}

@test "--check reports drift, writes nothing, and passes once complete" {
  seed_changelog
  local before
  before="$(cat "${CL}")"
  run bump --check --repo-root "${REPO}"
  assert_failure
  assert_equal "$(cat "${CL}")" "${before}"

  run bump --links-only --repo-root "${REPO}"
  assert_success
  run bump --check --repo-root "${REPO}"
  assert_success
}

@test "regeneration is idempotent" {
  seed_changelog
  bump --links-only --repo-root "${REPO}"
  local once
  once="$(cat "${CL}")"
  bump --links-only --repo-root "${REPO}"
  assert_equal "$(cat "${CL}")" "${once}"
}

@test "refuses to bump a version the changelog already records" {
  seed_changelog
  run bump v0.6.8 --repo-root "${REPO}" --date 2026-04-21
  assert_failure
  assert_output --partial 'v0.6.8'
}

@test "refuses when there is no Unreleased section to promote" {
  printf '# Changelog\n\n## [v0.6.8] - 2026-04-20\n\n- eight\n' > "${CL}"
  run bump v0.6.9 --repo-root "${REPO}" --date 2026-04-21
  assert_failure
  assert_output --partial 'Unreleased'
}

@test "derives the slug from the remote, so a renamed repo self-corrects" {
  seed_changelog
  git -C "${REPO}" remote set-url origin git@github.com:ycpss91255-docker/multi_run.git
  run bump --links-only --repo-root "${REPO}"
  assert_success
  run grep -c 'github.com/ycpss91255-docker/multi_run/' "${CL}"
  refute_output '0'
}

# --- split changelog layout (refs #307) -------------------------------------
#
# `ycpss91255-docker/base`#926 split the changelog into one file per `0.Y`
# series behind a GENERATED index. `doc/changelog/CHANGELOG.md` is now that
# index: it carries no release section, and base's `changelog-layout` lint
# refuses one there. The live `## [Unreleased]` lives in the series file.
#
# Every test above uses the pre-split fixture, which is exactly why a
# hardcoded `doc/changelog/CHANGELOG.md` default shipped and stopped base's
# v0.43.0-rc2 release with a message that named a path and never said what it
# wanted from it.

# seed_split -- index + two series files, the newest carrying [Unreleased].
seed_split() {
  printf '# Changelog\n\nGenerated index -- do not hand-edit.\n\n| Series | File |\n|---|---|\n| v0.43 | [v0.43.md](v0.43.md) |\n' \
    > "${CL}"
  printf '# v0.42\n\n## [v0.6.8] - 2026-04-20\n\n- eight\n' \
    > "${REPO}/doc/changelog/v0.42.md"
  printf '# v0.43\n\n## [Unreleased]\n\n### Fixed\n- something\n\n## [v0.43.0] - 2026-09-01\n\n- shipped\n' \
    > "${REPO}/doc/changelog/v0.43.md"
}

@test "split layout: promotes the series file and leaves the generated index alone" {
  seed_split
  local index_before
  index_before="$(cat "${CL}")"
  run bump v0.6.9 --repo-root "${REPO}" --date 2026-04-21
  assert_success
  assert_equal "$(cat "${CL}")" "${index_before}"
  run grep -c '^## \[v0.6.9\] - 2026-04-21' "${REPO}/doc/changelog/v0.43.md"
  assert_output '1'
  assert_equal "$(cat "${REPO}/.version")" 'v0.6.9'
}

@test "split layout: the link block lands in the series file, not the index" {
  seed_split
  run bump --links-only --repo-root "${REPO}"
  assert_success
  run grep -c '^\[Unreleased\]: https://github.com/ycpss91255-docker/base/compare/' \
    "${REPO}/doc/changelog/v0.43.md"
  assert_output '1'
  run grep -c 'https://github.com' "${CL}"
  assert_output '0'
}

@test "split layout: the rule follows the series to v0.44 with nothing to edit" {
  seed_split
  printf '# v0.43\n\n## [v0.43.0] - 2026-09-01\n\n- shipped\n' \
    > "${REPO}/doc/changelog/v0.43.md"
  printf '# v0.44\n\n## [Unreleased]\n\n### Added\n- next\n' \
    > "${REPO}/doc/changelog/v0.44.md"
  run bump v0.44.0 --repo-root "${REPO}" --date 2026-09-05
  assert_success
  run grep -c '^## \[v0.44.0\] - 2026-09-05' "${REPO}/doc/changelog/v0.44.md"
  assert_output '1'
  run grep -c '^## \[v0.44.0\]' "${REPO}/doc/changelog/v0.43.md"
  assert_output '0'
}

@test "refuses when nothing under doc/changelog carries Unreleased, and says so" {
  printf '# Changelog\n\nGenerated index -- do not hand-edit.\n' > "${CL}"
  run bump v0.6.9 --repo-root "${REPO}" --date 2026-04-21
  assert_failure 1
  assert_output --partial 'Unreleased'
  assert_output --partial "${REPO}/doc/changelog"
  assert_output --partial 'CHANGELOG.md'
  assert_output --partial '--changelog'
}

@test "refuses when several files carry Unreleased, naming each candidate" {
  seed_split
  printf '# v0.42\n\n## [Unreleased]\n\n- stale\n' \
    > "${REPO}/doc/changelog/v0.42.md"
  run bump v0.6.9 --repo-root "${REPO}" --date 2026-04-21
  assert_failure 1
  assert_output --partial 'doc/changelog/v0.42.md'
  assert_output --partial 'doc/changelog/v0.43.md'
}

@test "--changelog still overrides the derivation for a layout the rule cannot see" {
  seed_split
  mkdir -p "${REPO}/other"
  printf '# elsewhere\n\n## [Unreleased]\n\n- x\n' > "${REPO}/other/LOG.md"
  run bump v0.6.9 --repo-root "${REPO}" --changelog "${REPO}/other/LOG.md" --date 2026-04-21
  assert_success
  run grep -c '^## \[v0.6.9\]' "${REPO}/other/LOG.md"
  assert_output '1'
  run grep -c '^## \[v0.6.9\]' "${REPO}/doc/changelog/v0.43.md"
  assert_output '0'
}
