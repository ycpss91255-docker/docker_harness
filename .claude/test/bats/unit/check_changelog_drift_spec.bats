#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  REPO="$(mktemp_repo changelog)"
}

teardown() {
  rm -rf "${REPO}"
}

@test "fires when code staged without CHANGELOG" {
  ( cd "${REPO}" && echo "echo bye" > script/foo.sh && git add script/foo.sh )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"git commit -m foo\"},\"cwd\":\"${REPO}\"}"
  assert_message_contains "CHANGELOG drift"
}

@test "silent when code AND CHANGELOG staged together" {
  ( cd "${REPO}" && echo "echo bye" > script/foo.sh && echo "## [Unreleased]" >> doc/changelog/CHANGELOG.md && git add script/foo.sh doc/changelog/CHANGELOG.md )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"git commit -m foo\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent when only docs staged" {
  ( cd "${REPO}" && echo "doc only" > NOTE.md && git add NOTE.md )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"git commit -m foo\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent on --amend" {
  ( cd "${REPO}" && echo "echo bye" > script/foo.sh && git add script/foo.sh )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"git commit --amend --no-edit\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent in repo without doc/changelog/CHANGELOG.md (rule N/A)" {
  local repo
  repo="$(mktemp_repo)"
  ( cd "${repo}" && echo "echo bye" > script/foo.sh && git add script/foo.sh )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"git commit -m foo\"},\"cwd\":\"${repo}\"}"
  assert_silent
  rm -rf "${repo}"
}

@test "resolves repo via cd subdir && git commit" {
  ( cd "${REPO}" && echo "echo bye" > script/foo.sh && git add script/foo.sh )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"cd ${REPO} && git commit -m foo\"},\"cwd\":\"/tmp\"}"
  assert_message_contains "CHANGELOG drift"
}

# --- split changelog layout (refs #308) -------------------------------------
#
# After `ycpss91255-docker/base`#926, `doc/changelog/CHANGELOG.md` is a
# GENERATED index and base's `changelog-layout` lint refuses a release section
# in it. Asking a commit for that file asks for the one file it must NOT
# hand-edit, and every code commit on base tripped the warning while correctly
# editing `doc/changelog/v0.43.md`. A warning that is always wrong is one
# people learn to scroll past -- and it is the same warning that fires when
# someone genuinely forgot the entry.

# mktemp_split_repo -- a repo shaped like base after the split: a generated
# index carrying no release section, plus a series file carrying the live
# `[Unreleased]`.
mktemp_split_repo() {
  local dir
  dir="$(mktemp -d)"
  (
    cd "${dir}" || exit 1
    git init -q -b main
    git config user.email "t@t"
    git config user.name "t"
    mkdir -p doc/changelog script
    printf '# Changelog\n\nGenerated index -- do not hand-edit.\n\n| Series | File |\n|---|---|\n| v0.43 | [v0.43.md](v0.43.md) |\n' \
      > doc/changelog/CHANGELOG.md
    printf '# v0.43\n\n## [Unreleased]\n\n### Fixed\n- something\n' \
      > doc/changelog/v0.43.md
    echo "echo init" > script/foo.sh
    git add -A >/dev/null
    git commit -q -m init
  ) >/dev/null
  echo "${dir}"
}

@test "split layout: silent when the commit edits only the series file" {
  local repo
  repo="$(mktemp_split_repo)"
  ( cd "${repo}" && echo "echo bye" > script/foo.sh \
      && printf -- '- another\n' >> doc/changelog/v0.43.md \
      && git add script/foo.sh doc/changelog/v0.43.md )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"git commit -m foo\"},\"cwd\":\"${repo}\"}"
  assert_silent
  rm -rf "${repo}"
}

@test "split layout: a code commit with no changelog edit still warns, naming the series file" {
  local repo
  repo="$(mktemp_split_repo)"
  ( cd "${repo}" && echo "echo bye" > script/foo.sh && git add script/foo.sh )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"git commit -m foo\"},\"cwd\":\"${repo}\"}"
  assert_message_contains "CHANGELOG drift"
  assert_message_contains "doc/changelog/v0.43.md"
  rm -rf "${repo}"
}

@test "split layout: never asks for the generated index" {
  local repo
  repo="$(mktemp_split_repo)"
  ( cd "${repo}" && echo "echo bye" > script/foo.sh && git add script/foo.sh )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"git commit -m foo\"},\"cwd\":\"${repo}\"}"
  assert_success
  refute_output --partial "doc/changelog/CHANGELOG.md"
  rm -rf "${repo}"
}

@test "silent when no file under doc/changelog carries [Unreleased] (rule N/A)" {
  local repo
  repo="$(mktemp_split_repo)"
  ( cd "${repo}" && rm doc/changelog/v0.43.md && git add -A && git commit -q -m drop )
  ( cd "${repo}" && echo "echo bye" > script/foo.sh && git add script/foo.sh )
  run "$(hook check_changelog_drift.sh)" <<< "{\"tool_input\":{\"command\":\"git commit -m foo\"},\"cwd\":\"${repo}\"}"
  assert_silent
  rm -rf "${repo}"
}
