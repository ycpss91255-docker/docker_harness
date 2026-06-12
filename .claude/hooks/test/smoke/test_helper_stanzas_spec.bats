#!/usr/bin/env bats

# Covers the write_bats_stanzas helper in test_helper.bash (refs #166).
# The helper must produce a real .bats fixture with N trivial @test
# stanzas WITHOUT tripping the bats preprocessor heredoc trap.

load '../lib/test_helper'

setup() {
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

@test "write_bats_stanzas writes count real @test stanzas + shebang" {
  local f="${TMP}/fixture.bats"
  write_bats_stanzas "${f}" 3
  [[ -f "${f}" ]] || { echo "file not created"; return 1; }
  local first
  first="$(head -1 "${f}")"
  [[ "${first}" == '#!/usr/bin/env bats' ]] \
    || { echo "missing shebang, got: ${first}"; return 1; }
  local n
  n="$(grep -c '^@test' "${f}")"
  [[ "${n}" == "3" ]] || { echo "want 3 @test, got ${n}"; cat "${f}"; return 1; }
  grep -q '^@test "t0" { :; }$' "${f}" || { echo "missing t0 stanza"; cat "${f}"; return 1; }
  grep -q '^@test "t2" { :; }$' "${f}" || { echo "missing t2 stanza"; cat "${f}"; return 1; }
}

@test "write_bats_stanzas count=0 yields shebang only, zero @test" {
  local f="${TMP}/empty.bats"
  write_bats_stanzas "${f}" 0
  [[ -f "${f}" ]] || { echo "file not created"; return 1; }
  local lines
  lines="$(wc -l < "${f}")"
  [[ "${lines}" == "1" ]] || { echo "want 1 line (shebang), got ${lines}"; cat "${f}"; return 1; }
  local n
  n="$(grep -c '^@test' "${f}" || true)"
  [[ "${n}" == "0" ]] || { echo "want 0 @test, got ${n}"; cat "${f}"; return 1; }
}
