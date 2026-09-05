#!/usr/bin/env bats

# Covers .claude/scripts/lib/changelog-path.sh -- the one reader for "which
# file is this repo's live changelog" (refs #307, #308).
#
# Why a library rather than a literal in each caller: the path
# `doc/changelog/CHANGELOG.md` was written out in seven places, and
# `ycpss91255-docker/base`#926 then split the changelog into one file per
# `0.Y` series behind a GENERATED index. Every one of those seven literals
# silently changed meaning at once -- the release primitive refused to
# promote, the drift hook asked commits for the file they must NOT hand-edit,
# and two scanners exempted the generated index instead of the prose. Four
# copies of a walk is how one wrong path became seven.
#
# The rule the library implements is base's own `changelog-layout` invariant:
# exactly ONE file under `doc/changelog/` carries `## [Unreleased]`, and that
# file is the live one. On the pre-split layout that file IS `CHANGELOG.md`,
# so a repo that has not split sees no change and needs no configuration.
#
# It fails closed: zero matches or several must refuse and say what was
# looked for, because a repo whose changelog lives somewhere else deserves an
# actionable message rather than a guess at a filename.

load '../lib/test_helper'

setup() {
  ROOT="$(mktemp -d)"
  mkdir -p "${ROOT}/doc/changelog"
}

teardown() {
  rm -rf "${ROOT}"
}

# seed_presplit -- the layout every repo in the org had before base#926: one
# CHANGELOG.md carrying the live section.
seed_presplit() {
  printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n- something\n' \
    > "${ROOT}/doc/changelog/CHANGELOG.md"
}

# seed_split -- base's layout after #926: CHANGELOG.md is the generated index
# (no release section at all -- the changelog-layout lint refuses one there)
# and the live `[Unreleased]` lives in the current series file.
seed_split() {
  printf '# Changelog\n\nGenerated index -- do not hand-edit.\n\n| Series | File |\n|---|---|\n| v0.43 | [v0.43.md](v0.43.md) |\n| v0.42 | [v0.42.md](v0.42.md) |\n' \
    > "${ROOT}/doc/changelog/CHANGELOG.md"
  printf '# v0.42\n\n## [v0.42.0] - 2026-06-01\n\n- old\n' \
    > "${ROOT}/doc/changelog/v0.42.md"
  printf '# v0.43\n\n## [Unreleased]\n\n### Fixed\n- something\n' \
    > "${ROOT}/doc/changelog/v0.43.md"
}

lib() {
  run bash -c "source '${SCRIPTS_DIR}/lib/changelog-path.sh'; $*"
}

@test "pre-split layout: the live file is CHANGELOG.md" {
  seed_presplit
  lib "changelog_live_file '${ROOT}'"
  assert_success
  assert_output "${ROOT}/doc/changelog/CHANGELOG.md"
}

@test "split layout: the live file is the series file, not the generated index" {
  seed_split
  lib "changelog_live_file '${ROOT}'"
  assert_success
  assert_output "${ROOT}/doc/changelog/v0.43.md"
}

@test "the rule follows the series forward without an edit" {
  # The whole point of deriving: when v0.43 is closed out and v0.44 opens,
  # nobody updates a default, a flag, or a doc.
  seed_split
  printf '# v0.43\n\n## [v0.43.0] - 2026-09-01\n\n- shipped\n' \
    > "${ROOT}/doc/changelog/v0.43.md"
  printf '# v0.44\n\n## [Unreleased]\n\n### Added\n- next\n' \
    > "${ROOT}/doc/changelog/v0.44.md"
  lib "changelog_live_file '${ROOT}'"
  assert_success
  assert_output "${ROOT}/doc/changelog/v0.44.md"
}

@test "changelog_live_rel prints the path a commit and a git diff use" {
  seed_split
  lib "changelog_live_rel '${ROOT}'"
  assert_success
  assert_output 'doc/changelog/v0.43.md'
}

@test "refuses when no file carries [Unreleased], naming what it searched" {
  printf '# Changelog\n\n## [v0.6.8] - 2026-04-20\n\n- eight\n' \
    > "${ROOT}/doc/changelog/CHANGELOG.md"
  lib "changelog_live_file '${ROOT}'"
  assert_failure
  assert_output ''

  lib "changelog_why_no_live_file '${ROOT}'"
  assert_success
  assert_output --partial '## [Unreleased]'
  assert_output --partial "${ROOT}/doc/changelog"
  assert_output --partial 'doc/changelog/CHANGELOG.md'
}

@test "refuses when several files carry [Unreleased], naming every one" {
  seed_split
  printf '# v0.42\n\n## [Unreleased]\n\n- stale\n' \
    > "${ROOT}/doc/changelog/v0.42.md"
  lib "changelog_live_file '${ROOT}'"
  assert_failure
  assert_output ''

  lib "changelog_why_no_live_file '${ROOT}'"
  assert_success
  assert_output --partial 'doc/changelog/v0.42.md'
  assert_output --partial 'doc/changelog/v0.43.md'
  refute_output --partial 'doc/changelog/CHANGELOG.md'
}

@test "refuses when there is no doc/changelog directory at all" {
  rm -rf "${ROOT}/doc"
  lib "changelog_live_file '${ROOT}'"
  assert_failure
  lib "changelog_why_no_live_file '${ROOT}'"
  assert_success
  assert_output --partial "${ROOT}/doc/changelog"
}

@test "changelog_files lists the markdown in the directory and nothing else" {
  seed_split
  : > "${ROOT}/doc/changelog/.keep"
  : > "${ROOT}/doc/changelog/notes.txt"
  lib "changelog_files '${ROOT}'"
  assert_success
  assert_line "${ROOT}/doc/changelog/CHANGELOG.md"
  assert_line "${ROOT}/doc/changelog/v0.43.md"
  refute_output --partial 'notes.txt'
}

@test "a trailing slash on the root does not double up in the path" {
  seed_presplit
  lib "changelog_live_file '${ROOT}/'"
  assert_success
  assert_output "${ROOT}/doc/changelog/CHANGELOG.md"
}
