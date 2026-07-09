#!/usr/bin/env bats

load '../lib/test_helper'

# mktemp_downstream_repo <category> <repo_name> — make a fake docker
# monorepo layout under TMP/<category>/<repo_name>/ with empty
# README.md + 3 translation stubs. Echoes the repo root.
# <category> must be agent / app / env (matching the hook's category list).
mktemp_downstream_repo() {
  local category="$1"
  local repo="$2"
  local root
  root="$(mktemp -d)"
  mkdir -p "${root}/${category}/${repo}/doc"
  : > "${root}/${category}/${repo}/README.md"
  : > "${root}/${category}/${repo}/doc/README.zh-TW.md"
  : > "${root}/${category}/${repo}/doc/README.zh-CN.md"
  : > "${root}/${category}/${repo}/doc/README.ja.md"
  echo "${root}/${category}/${repo}"
}

# write_aligned <readme_path> — write a minimally framework-compliant
# README to <readme_path>. All 6 checks should pass.
write_aligned() {
  local p="$1"
  cat > "${p}" <<'EOF'
# Some Repo

[![CI](https://github.com/ycpss91255-docker/some_repo/actions/workflows/main.yaml/badge.svg)](https://github.com/ycpss91255-docker/some_repo/actions/workflows/main.yaml)

One-liner.

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

## TL;DR

```bash
./build.sh && ./run.sh
```

## Smoke Tests

See [TEST.md](doc/test/TEST.md) for details.
EOF
}

@test "silent on a fully aligned English README" {
  local repo
  repo="$(mktemp_downstream_repo agent foo)"
  write_aligned "${repo}/README.md"
  write_aligned "${repo}/doc/README.zh-TW.md"
  write_aligned "${repo}/doc/README.zh-CN.md"
  write_aligned "${repo}/doc/README.ja.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/README.md\"}}"
  assert_silent
  rm -rf "${repo%/*/*}"
}

@test "[1] fires on missing CI badge" {
  local repo
  repo="$(mktemp_downstream_repo agent foo)"
  write_aligned "${repo}/README.md"
  # Strip the badge line.
  sed -i '/badge.svg/d' "${repo}/README.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/README.md\"}}"
  assert_message_contains "[1] missing CI badge"
  rm -rf "${repo%/*/*}"
}

@test "[2] fires on missing 4-language link" {
  local repo
  repo="$(mktemp_downstream_repo agent foo)"
  write_aligned "${repo}/README.md"
  sed -i '/\*\*\[English\]/d' "${repo}/README.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/README.md\"}}"
  assert_message_contains "[2] missing 4-language switch link"
  rm -rf "${repo%/*/*}"
}

@test "[3] fires when TL;DR is a blockquote" {
  local repo
  repo="$(mktemp_downstream_repo agent foo)"
  write_aligned "${repo}/README.md"
  printf '\n> **TL;DR** legacy blockquote\n' >> "${repo}/README.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/README.md\"}}"
  assert_message_contains "[3] TL;DR is a blockquote"
  rm -rf "${repo%/*/*}"
}

@test "[4] fires on stale .base/build.sh symlink target" {
  local repo
  repo="$(mktemp_downstream_repo app bar)"
  write_aligned "${repo}/README.md"
  printf '\nbuild.sh -> .base/build.sh    # Symlink\n' >> "${repo}/README.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/README.md\"}}"
  assert_message_contains "stale path '.base/build.sh'"
  rm -rf "${repo%/*/*}"
}

@test "[5] fires on .template_version reference" {
  local repo
  repo="$(mktemp_downstream_repo env baz)"
  write_aligned "${repo}/README.md"
  printf '\n.template_version            # Template subtree version\n' >> "${repo}/README.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/README.md\"}}"
  assert_message_contains "[5] obsolete '.template_version' reference"
  rm -rf "${repo%/*/*}"
}

@test "[6] fires on missing TEST.md link" {
  local repo
  repo="$(mktemp_downstream_repo agent foo)"
  write_aligned "${repo}/README.md"
  sed -i '/doc\/test\/TEST.md/d' "${repo}/README.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/README.md\"}}"
  assert_message_contains "[6] missing 'See [TEST.md]"
  rm -rf "${repo%/*/*}"
}

@test "[drift] fires when a translation has no CI badge while English does" {
  local repo
  repo="$(mktemp_downstream_repo app bar)"
  write_aligned "${repo}/README.md"
  # zh-TW intentionally left empty (no badge), zh-CN + ja aligned.
  : > "${repo}/doc/README.zh-TW.md"
  write_aligned "${repo}/doc/README.zh-CN.md"
  write_aligned "${repo}/doc/README.ja.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/README.md\"}}"
  assert_message_contains "[drift] doc/README.zh-TW.md has not adopted the framework yet"
  rm -rf "${repo%/*/*}"
}

@test "[drift] fires when a translation file is missing entirely" {
  local repo
  repo="$(mktemp_downstream_repo agent foo)"
  write_aligned "${repo}/README.md"
  rm "${repo}/doc/README.ja.md"
  write_aligned "${repo}/doc/README.zh-TW.md"
  write_aligned "${repo}/doc/README.zh-CN.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/README.md\"}}"
  assert_message_contains "missing translation: doc/README.ja.md"
  rm -rf "${repo%/*/*}"
}

@test "checks a translation file directly with [zh-TW] label" {
  local repo
  repo="$(mktemp_downstream_repo env baz)"
  write_aligned "${repo}/README.md"
  : > "${repo}/doc/README.zh-TW.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/doc/README.zh-TW.md\"}}"
  assert_message_contains "[zh-TW] [1] missing CI badge"
  rm -rf "${repo%/*/*}"
}

@test "silent when editing .base/README.md (the framework reference itself)" {
  local root
  root="$(mktemp -d)"
  mkdir -p "${root}/.base"
  cat > "${root}/.base/README.md" <<'EOF'
# template
no badge no nothing
EOF
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${root}/.base/README.md\"}}"
  assert_silent
  rm -rf "${root}"
}

@test "silent when editing archive/<repo>/README.md (read-only archive)" {
  local root
  root="$(mktemp -d)"
  mkdir -p "${root}/archive/old_repo"
  : > "${root}/archive/old_repo/README.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${root}/archive/old_repo/README.md\"}}"
  assert_silent
  rm -rf "${root}"
}

@test "silent when editing a non-README file" {
  run "$(hook check_readme_framework.sh)" <<< '{"tool_input":{"file_path":"/tmp/not_a_readme.txt"}}'
  assert_silent
}

@test "silent on multi_run/README.md when fully aligned" {
  local root
  root="$(mktemp -d)"
  mkdir -p "${root}/multi_run/doc"
  write_aligned "${root}/multi_run/README.md"
  write_aligned "${root}/multi_run/doc/README.zh-TW.md"
  write_aligned "${root}/multi_run/doc/README.zh-CN.md"
  write_aligned "${root}/multi_run/doc/README.ja.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${root}/multi_run/README.md\"}}"
  assert_silent
  rm -rf "${root}"
}

# [7] Directory Structure tree walker (refs issue #65). Each test sets
# up a minimal downstream repo, appends a "## Directory Structure" code
# fence to the aligned README, optionally materializes / omits matching
# files on disk, and asserts the [7] line is emitted (or not).

# write_all_aligned <repo> — populate English README + 3 translation
# files with framework-compliant minimal content so [drift] checks do
# not fire. Used by [7] tests that focus only on the tree-walker.
write_all_aligned() {
  local repo="$1"
  write_aligned "${repo}/README.md"
  write_aligned "${repo}/doc/README.zh-TW.md"
  write_aligned "${repo}/doc/README.zh-CN.md"
  write_aligned "${repo}/doc/README.ja.md"
}

@test "[7] silent when every tree path exists on disk (positive control)" {
  local repo
  repo="$(mktemp_downstream_repo app bridge)"
  write_all_aligned "${repo}"
  mkdir -p "${repo}/config/ros1_bridge"
  : > "${repo}/config/ros1_bridge/scan_bridge.yaml"
  : > "${repo}/Dockerfile"
  printf '\n## Directory Structure\n\n```text\nbridge/\n├── Dockerfile                # multi-stage\n├── config/\n│   └── ros1_bridge/             # bridge configs\n│       └── scan_bridge.yaml     # LaserScan bridge\n```\n' >> "${repo}/README.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/README.md\"}}"
  assert_silent
  rm -rf "${repo%/*/*}"
}

@test "[7] fires when tree path does not exist on disk (the #65 drift)" {
  local repo
  repo="$(mktemp_downstream_repo app bridge)"
  write_all_aligned "${repo}"
  # config/ros1_bridge/scan_bridge.yaml exists on disk
  mkdir -p "${repo}/config/ros1_bridge"
  : > "${repo}/config/ros1_bridge/scan_bridge.yaml"
  # README still references the pre-rename flat path config/scan_bridge.yaml
  printf '\n## Directory Structure\n\n```text\nbridge/\n├── config/\n│   ├── scan_bridge.yaml      # LaserScan bridge\n│   └── release_bridge.yaml   # Camera bridge\n```\n' >> "${repo}/README.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/README.md\"}}"
  assert_message_contains "stale path 'config/scan_bridge.yaml'"
  assert_message_contains "stale path 'config/release_bridge.yaml'"
  rm -rf "${repo%/*/*}"
}

@test "[7] ignores ellipsis and pure tree-art lines" {
  local repo
  repo="$(mktemp_downstream_repo agent foo)"
  write_all_aligned "${repo}"
  : > "${repo}/Dockerfile"
  printf '\n## Directory Structure\n\n```text\nfoo/\n├── Dockerfile\n│\n├── ...\n└── ...\n```\n' >> "${repo}/README.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/README.md\"}}"
  assert_silent
  rm -rf "${repo%/*/*}"
}

@test "[7] symlink notation 'build.sh -> .base/...' checks the link not the target" {
  local repo
  repo="$(mktemp_downstream_repo app sym)"
  write_all_aligned "${repo}"
  # build.sh on disk as a broken symlink (target intentionally missing)
  ln -s ".base/script/docker/build.sh" "${repo}/build.sh"
  printf '\n## Directory Structure\n\n```text\nsym/\n├── build.sh -> .base/script/docker/build.sh   # Symlink\n```\n' >> "${repo}/README.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/README.md\"}}"
  refute_output --partial "stale path 'build.sh'"
  refute_output --partial "stale path '.base"
  rm -rf "${repo%/*/*}"
}

@test "[7] zh-TW heading '## 目錄結構' is recognized" {
  local repo
  repo="$(mktemp_downstream_repo agent zhfoo)"
  write_all_aligned "${repo}"
  printf '\n## 目錄結構\n\n```text\nzhfoo/\n├── nonexistent.yaml      # missing\n```\n' >> "${repo}/doc/README.zh-TW.md"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/doc/README.zh-TW.md\"}}"
  assert_message_contains "stale path 'nonexistent.yaml'"
  rm -rf "${repo%/*/*}"
}

@test "[7] silent when README has no Directory Structure section" {
  local repo
  repo="$(mktemp_downstream_repo agent nodir)"
  write_all_aligned "${repo}"
  run "$(hook check_readme_framework.sh)" <<< "{\"tool_input\":{\"file_path\":\"${repo}/README.md\"}}"
  assert_silent
  rm -rf "${repo%/*/*}"
}
