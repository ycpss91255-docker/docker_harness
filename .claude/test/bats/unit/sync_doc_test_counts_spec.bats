#!/usr/bin/env bats
#
# Unit specs for .claude/scripts/sync-doc-test-counts.sh -- the generator
# that derives doc/test/*.md from the spec tree (refs #265).
#
# Fixtures use the `test/<level>/` layout the script probes as a fallback,
# so a fixture repo needs nothing from this repo's own `.claude/` tree.
#
# NOTE on fixture authoring: bats rewrites any line starting with `@test` at
# column 0 in THIS file before bash ever sees it, heredoc bodies included
# (see write_bats_stanzas in lib/test_helper.bash). Every fixture spec is
# therefore built with printf, never with a heredoc.

load '../lib/test_helper'

setup() {
  SCRIPT="$(script sync-doc-test-counts.sh)"
  REPO="$(mktemp -d)"
  mkdir -p "${REPO}/test/unit" "${REPO}/doc/test"
}

teardown() {
  [[ -n "${REPO:-}" ]] && rm -rf "${REPO}"
}

# mk_spec <relpath> <test-name>... -- write a bats fixture whose `@test`
# stanzas carry the given names, in the given order.
mk_spec() {
  local rel="$1"
  shift
  local name
  {
    printf '#!/usr/bin/env bats\n'
    for name in "$@"; do
      printf '@test "%s" {\n  :\n}\n' "${name}"
    done
  } > "${REPO}/${rel}"
}

# mk_doc <basename> <line>... -- write a doc/test catalog from literal lines.
mk_doc() {
  local base="$1"
  shift
  printf '%s\n' "$@" > "${REPO}/doc/test/${base}"
}

@test "--help prints usage and exits 0" {
  run "${SCRIPT}" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--check"
}

@test "unknown flag exits 2" {
  run "${SCRIPT}" --bogus "${REPO}"
  assert_failure 2
}

@test "repo root without doc/test exits 2" {
  run "${SCRIPT}" "$(mktemp -d)"
  assert_failure 2
  assert_output --partial "no doc/test"
}

@test "heading count is regenerated from the spec file" {
  mk_spec test/unit/a_spec.bats one two three
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (99)'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run grep -c '^### test/unit/a_spec.bats (3)$' "${REPO}/doc/test/unit.md"
  assert_output "1"
}

@test "section whose spec file no longer exists is dropped whole" {
  mk_spec test/unit/a_spec.bats one
  mk_doc unit.md '# Unit' '' '### test/unit/gone_spec.bats (7)' \
    '| Test | Scenario |' '|------|----------|' '| old | prose |' '' \
    '### test/unit/a_spec.bats (1)'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run grep -c 'gone_spec' "${REPO}/doc/test/unit.md"
  assert_output "0"
  run grep -c '^### test/unit/a_spec.bats (1)$' "${REPO}/doc/test/unit.md"
  assert_output "1"
}

@test "spec file with no section gets one appended, with its rows" {
  mk_spec test/unit/a_spec.bats one
  mk_spec test/unit/b_spec.bats 'first b' 'second b'
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (1)' \
    '| Test | Scenario |' '|------|----------|' '| one | kept |'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run cat "${REPO}/doc/test/unit.md"
  assert_output --partial '### test/unit/b_spec.bats (2)'
  assert_output --partial '| first b | - |'
  assert_output --partial '| second b | - |'
}

@test "a hand-written description survives regeneration" {
  mk_spec test/unit/a_spec.bats one two
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (1)' \
    '| Test | Scenario |' '|------|----------|' \
    '| one | carefully written prose |'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run cat "${REPO}/doc/test/unit.md"
  assert_output --partial '| one | carefully written prose |'
  assert_output --partial '| two | - |'
}

@test "row naming a deleted test is dropped" {
  mk_spec test/unit/a_spec.bats one
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (2)' \
    '| Test | Scenario |' '|------|----------|' '| one | kept |' \
    '| removed test | stale prose |'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run grep -c 'removed test' "${REPO}/doc/test/unit.md"
  assert_output "0"
}

@test "a renamed test is delete-plus-add: prose does not follow the rename" {
  mk_spec test/unit/a_spec.bats 'one renamed'
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (1)' \
    '| Test | Scenario |' '|------|----------|' '| one | old prose |'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run cat "${REPO}/doc/test/unit.md"
  assert_output --partial '| one renamed | - |'
  refute_output --partial 'old prose'
}

@test "rows follow spec file order, not the doc's previous order" {
  mk_spec test/unit/a_spec.bats zebra alpha
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (2)' \
    '| Test | Scenario |' '|------|----------|' '| alpha | A |' \
    '| zebra | Z |'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run grep -nE '^\| (zebra|alpha) ' "${REPO}/doc/test/unit.md"
  assert_line --index 0 --partial '| zebra | Z |'
  assert_line --index 1 --partial '| alpha | A |'
}

@test "a pipe in a test name is escaped and round-trips" {
  mk_spec test/unit/a_spec.bats 'silent on foo | xargs'
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (1)' \
    '| Test | Scenario |' '|------|----------|' \
    '| silent on foo \| xargs | pipe guard |'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run cat "${REPO}/doc/test/unit.md"
  assert_output --partial '| silent on foo \| xargs | pipe guard |'
}

@test "an angle bracket in a test name is escaped so markdown keeps it" {
  mk_spec test/unit/a_spec.bats 'missing <tag> exits 2'
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (1)' \
    '| Test | Scenario |' '|------|----------|' \
    '| missing \<tag\> exits 2 | arg validation |'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run cat "${REPO}/doc/test/unit.md"
  assert_output --partial '| missing \<tag> exits 2 | arg validation |'
}

@test "a section with no Test table keeps its prose untouched" {
  mk_spec test/unit/a_spec.bats one two
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (99)' '' \
    'Summarised by category on purpose.' '' '| Category | Tests |' \
    '|----------|-------|' '| guards | 2 |'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run cat "${REPO}/doc/test/unit.md"
  assert_output --partial 'Summarised by category on purpose.'
  assert_output --partial '| guards | 2 |'
  assert_output --partial '### test/unit/a_spec.bats (2)'
}

@test "the per-level **N tests** total is regenerated" {
  mk_spec test/unit/a_spec.bats one two
  mk_spec test/unit/b_spec.bats three
  mk_doc unit.md '# Unit' '' 'Unit level: **99 tests** across 1 specs.' '' \
    '### test/unit/a_spec.bats (2)' '### test/unit/b_spec.bats (1)'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run cat "${REPO}/doc/test/unit.md"
  assert_output --partial '**3 tests** across 2 specs'
}

@test "TEST.md grand total and index row are regenerated" {
  mk_spec test/unit/a_spec.bats one two
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (2)'
  mk_doc TEST.md '# Tests' '' 'Grand total (all levels): **99 tests**.' '' \
    '| Doc | Scope | Count |' '|-----|-------|-------|' \
    '| [unit.md](unit.md) | unit specs | 99 |'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run cat "${REPO}/doc/test/TEST.md"
  assert_output --partial 'Grand total (all levels): **2 tests**.'
  assert_output --partial '| [unit.md](unit.md) | unit specs | 2 |'
}

@test "--check exits 1 on drift, names the fix, and writes nothing" {
  mk_spec test/unit/a_spec.bats one two
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (99)'
  local before
  before="$(cat "${REPO}/doc/test/unit.md")"
  run "${SCRIPT}" --check "${REPO}"
  assert_failure 1
  assert_output --partial "sync-doc-test-counts.sh"
  [[ "$(cat "${REPO}/doc/test/unit.md")" == "${before}" ]]
}

@test "--check exits 0 once the docs are in sync" {
  mk_spec test/unit/a_spec.bats one two
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (99)'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run "${SCRIPT}" --check "${REPO}"
  assert_success
  assert_output --partial "in sync"
}

@test "regeneration is idempotent" {
  mk_spec test/unit/a_spec.bats one 'two <x>' 'three | four'
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (0)' \
    '| Test | Scenario |' '|------|----------|'
  run "${SCRIPT}" "${REPO}"
  assert_success
  cp "${REPO}/doc/test/unit.md" "${REPO}/first.md"
  run "${SCRIPT}" "${REPO}"
  assert_success
  run diff -u "${REPO}/first.md" "${REPO}/doc/test/unit.md"
  assert_success
}

@test "a Description column header is accepted as well as Scenario" {
  mk_spec test/unit/a_spec.bats one
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (1)' \
    '| Test | Description |' '|------|-------------|' '| one | kept |'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run cat "${REPO}/doc/test/unit.md"
  assert_output --partial '| Test | Description |'
  assert_output --partial '| one | kept |'
}

@test "a one-line @test stanza is catalogued like a multi-line one" {
  {
    printf '#!/usr/bin/env bats\n'
    printf '@test "inline body" { :; }\n'
    printf '@test "quoted \\"inner\\" string in body" { echo "y"; }\n'
  } > "${REPO}/test/unit/a_spec.bats"
  mk_doc unit.md '# Unit' '' '### test/unit/a_spec.bats (0)' \
    '| Test | Scenario |' '|------|----------|'
  run "${SCRIPT}" "${REPO}"
  assert_success
  run cat "${REPO}/doc/test/unit.md"
  assert_output --partial '### test/unit/a_spec.bats (2)'
  assert_output --partial '| inline body | - |'
  assert_output --partial '| quoted "inner" string in body | - |'
}
