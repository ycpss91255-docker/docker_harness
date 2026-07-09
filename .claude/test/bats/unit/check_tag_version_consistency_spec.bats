#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  REPO="$(mktemp -d)"
  ( cd "${REPO}" && git init -q -b main && git config user.email t@t && git config user.name t \
    && echo v0.18.0 > .version \
    && git add -A >/dev/null && git commit -q -m init ) >/dev/null
}

teardown() {
  rm -rf "${REPO}"
}

@test "blocks git tag -a when .version mismatches" {
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git tag -a v0.18.1 -m bump\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
  assert_message_contains "tag-version mismatch"
  assert_message_contains "v0.18.0"
}

@test "blocks lightweight git tag when .version mismatches" {
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git tag v0.18.1\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
}

@test "blocks git push origin <tag> when .version mismatches" {
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git push origin v0.18.1\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
}

@test "blocks git push origin refs/tags/<tag> when .version mismatches" {
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git push origin refs/tags/v0.18.1\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
}

@test "silent when .version matches tag exactly" {
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git tag -a v0.18.0 -m bump\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent for rc tag matching .version" {
  ( cd "${REPO}" && echo v0.19.0-rc1 > .version )
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git tag -a v0.19.0-rc1 -m rc\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "blocks rc tag when .version still on previous version" {
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git tag -a v0.19.0-rc1 -m rc\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
}

@test "silent when no .version at repo root (rule N/A)" {
  local repo
  repo="$(mktemp -d)"
  ( cd "${repo}" && git init -q -b main && git config user.email t@t && git config user.name t \
    && echo init > README.md && git add -A >/dev/null && git commit -q -m init ) >/dev/null
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git tag -a v1.0.0 -m one\"},\"cwd\":\"${repo}\"}"
  assert_silent
  rm -rf "${repo}"
}

@test "silent for downstream consumer with .base/.version (no root .version)" {
  local repo
  repo="$(mktemp -d)"
  ( cd "${repo}" && git init -q -b main && git config user.email t@t && git config user.name t \
    && mkdir -p .base && echo v0.18.0 > .base/.version \
    && git add -A >/dev/null && git commit -q -m init ) >/dev/null
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git tag -a v1.2.3 -m foo\"},\"cwd\":\"${repo}\"}"
  assert_silent
  rm -rf "${repo}"
}

@test "silent on git tag -d (delete)" {
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git tag -d v0.18.1\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent on git push delete (:tag)" {
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git push origin :v0.18.1\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent on git tag listing (no positional tag)" {
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git tag -l\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent on non-git command" {
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"ls -la\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "resolves repo via cd subdir && git tag" {
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"cd ${REPO} && git tag -a v0.18.1 -m bump\"},\"cwd\":\"/tmp\"}"
  assert_permission_decision "deny"
}

@test "resolves repo via git -C and blocks mismatch" {
  run "$(hook check_tag_version_consistency.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git -C ${REPO} tag -a v0.18.1 -m bump\"},\"cwd\":\"/tmp\"}"
  assert_permission_decision "deny"
}
