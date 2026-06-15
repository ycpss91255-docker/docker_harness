#!/usr/bin/env bats

load '../lib/test_helper'

@test "fires when TEST.md count > actual @test count" {
  local repo
  repo="$(mktemp_test_md_repo 3 5)"
  run "$(hook check_test_md_drift.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/test/unit/setup_spec.bats\"}}"
  assert_message_contains "TEST.md drift"
  rm -rf "${repo}"
}

@test "fires when TEST.md count < actual @test count" {
  local repo
  repo="$(mktemp_test_md_repo 5 3)"
  run "$(hook check_test_md_drift.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/doc/test/TEST.md\"}}"
  assert_message_contains "TEST.md drift"
  rm -rf "${repo}"
}

@test "silent when counts match" {
  local repo
  repo="$(mktemp_test_md_repo 4 4)"
  run "$(hook check_test_md_drift.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/test/unit/setup_spec.bats\"}}"
  assert_silent
  rm -rf "${repo}"
}

@test "fires when TEST.md lists missing bats file" {
  local repo
  repo="$(mktemp -d)"
  mkdir -p "${repo}/test" "${repo}/doc/test"
  cat > "${repo}/doc/test/TEST.md" <<'EOF'
### test/unit/missing_spec.bats (10)
EOF
  run "$(hook check_test_md_drift.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/doc/test/TEST.md\"}}"
  assert_message_contains "listed in TEST.md but file missing"
  rm -rf "${repo}"
}

@test "silent when edited file is not .bats or TEST.md" {
  run "$(hook check_test_md_drift.sh)" <<< '{"tool_input":{"file_path":"/tmp/foo.txt"}}'
  assert_silent
}

# Note: writing `@test ...` lines via heredoc is unsafe inside a .bats
# spec — bats's preprocessor scans every line of the spec file looking
# for `@test` at column 0 and rewrites them, even inside `<<'EOF'`
# heredocs. Use `printf` per line (or `echo` in `{ ... }`) so the
# stanza strings live inside an argument and never appear at column 0.
mktemp_base_drift_repo() {
  local base_count="$1" repo
  repo="$(mktemp -d)"
  mkdir -p "${repo}/test/smoke" "${repo}/.base/test/smoke" "${repo}/doc/test"
  write_bats_stanzas "${repo}/.base/test/smoke/script_help.bats" "${base_count}"
  echo "${repo}"
}

@test "fires when .base/test/smoke/*.bats count drifts (post base subtree upgrade)" {
  local repo
  repo="$(mktemp_base_drift_repo 3)"
  printf '### .base/test/smoke/script_help.bats (5)\n' > "${repo}/doc/test/TEST.md"
  run "$(hook check_test_md_drift.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/.base/test/smoke/script_help.bats\"}}"
  assert_message_contains "TEST.md drift"
  assert_message_contains ".base/test/smoke/script_help.bats: TEST.md says 5, actual 3"
  rm -rf "${repo}"
}

@test "silent when .base/test/smoke/*.bats count matches" {
  local repo
  repo="$(mktemp_base_drift_repo 4)"
  printf '### .base/test/smoke/script_help.bats (4)\n' > "${repo}/doc/test/TEST.md"
  run "$(hook check_test_md_drift.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/.base/test/smoke/script_help.bats\"}}"
  assert_silent
  rm -rf "${repo}"
}

@test "fires when .base/test/smoke/*.bats heading lists missing file" {
  local repo
  repo="$(mktemp -d)"
  mkdir -p "${repo}/test" "${repo}/.base/test/smoke" "${repo}/doc/test"
  printf '### .base/test/smoke/script_help.bats (10)\n' > "${repo}/doc/test/TEST.md"
  run "$(hook check_test_md_drift.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/doc/test/TEST.md\"}}"
  assert_message_contains ".base/test/smoke/script_help.bats: listed in TEST.md but file missing"
  rm -rf "${repo}"
}

@test "repo-local and .base/ entries both checked in same TEST.md" {
  local repo
  repo="$(mktemp_base_drift_repo 3)"
  {
    printf '#!/usr/bin/env bats\n'
    printf '@test "a" { :; }\n'
    printf '@test "b" { :; }\n'
  } > "${repo}/test/smoke/local_spec.bats"
  {
    printf '### test/smoke/local_spec.bats (2)\n'
    printf '### .base/test/smoke/script_help.bats (7)\n'
  } > "${repo}/doc/test/TEST.md"
  run "$(hook check_test_md_drift.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/doc/test/TEST.md\"}}"
  assert_message_contains ".base/test/smoke/script_help.bats: TEST.md says 7, actual 3"
  rm -rf "${repo}"
}

# ---- pytest counting (refs #198) ----
# A pytest file's count is its number of `def test_` function
# definitions (top-level + class methods), NOT pytest-collected cases
# (parametrize expands one def into many; the drift guard compares the
# def-count on both sides, so it stays consistent).

# write_pytest_defs <file> <count> — write a pytest module with <count>
# top-level `def test_N` functions.
write_pytest_defs() {
  local file="$1" count="$2" i=0
  {
    printf 'import pytest\n\n'
    while (( i < count )); do
      printf 'def test_%d():\n    assert True\n\n' "${i}"
      i=$((i + 1))
    done
  } > "${file}"
}

@test "fires when a pytest file's def test_ count drifts from TEST.md" {
  local repo
  repo="$(mktemp -d)"
  mkdir -p "${repo}/test/unit" "${repo}/doc/test"
  write_pytest_defs "${repo}/test/unit/widget_test.py" 3
  printf '### test/unit/widget_test.py (5)\n' > "${repo}/doc/test/TEST.md"
  run "$(hook check_test_md_drift.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/test/unit/widget_test.py\"}}"
  assert_message_contains "TEST.md drift"
  assert_message_contains "test/unit/widget_test.py: TEST.md says 5, actual 3"
  rm -rf "${repo}"
}
