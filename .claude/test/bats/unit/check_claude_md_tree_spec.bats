#!/usr/bin/env bats

load '../lib/test_helper'

# Build a fake project tree at $REPO_DIR with a CLAUDE.md and the named
# .claude/<dir>/<file> entries. CLAUDE.md is generated to match exactly
# what's listed via stdin (one entry per line, "<dir>:<file>" or
# "<dir>:<file>/" for placeholder dir).
#
# Usage:
#   make_fake_repo "$repo" \
#     "commands:audit.md" \
#     "scripts:wait-pr-ci.sh" \
#     "hooks:check_no_emoji.sh" \
#     "hooks:test/"
make_fake_repo() {
  local repo="$1"
  shift
  mkdir -p "${repo}/.claude/commands" "${repo}/.claude/scripts" "${repo}/.claude/hooks"

  # CLAUDE.md tree header
  {
    echo "# CLAUDE.md fake"
    echo ""
    echo '```'
    echo "docker/"
    echo "├── other/"
    echo "└── .claude/"
    echo "    ├── commands/"
    # placeholder; entries appended below
  } > "${repo}/CLAUDE.md.commands"

  : > "${repo}/CLAUDE.md.scripts.list"
  : > "${repo}/CLAUDE.md.hooks.list"
  : > "${repo}/CLAUDE.md.commands.list"

  local entry dir name
  for entry in "$@"; do
    dir="${entry%%:*}"
    name="${entry#*:}"
    # Decide if it's a directory placeholder (trailing slash)
    if [[ "${name}" == */ ]]; then
      local stem="${name%/}"
      mkdir -p "${repo}/.claude/${dir}/${stem}"
      printf '    │   ├── %s\n' "${name}" >> "${repo}/CLAUDE.md.${dir}.list"
    else
      : > "${repo}/.claude/${dir}/${name}"
      printf '    │   ├── %s              # entry\n' "${name}" >> "${repo}/CLAUDE.md.${dir}.list"
    fi
  done

  {
    echo "# CLAUDE.md fake"
    echo ""
    echo '```'
    echo "docker/"
    echo "└── .claude/"
    echo "    ├── commands/             # commands"
    cat "${repo}/CLAUDE.md.commands.list"
    echo "    ├── scripts/              # scripts"
    cat "${repo}/CLAUDE.md.scripts.list"
    echo "    ├── hooks/                # hooks"
    cat "${repo}/CLAUDE.md.hooks.list"
    echo "    └── settings.json         # settings"
    echo '```'
    echo ""
    echo "trailing prose."
  } > "${repo}/CLAUDE.md"

  rm -f "${repo}/CLAUDE.md.commands"  \
        "${repo}/CLAUDE.md.commands.list" \
        "${repo}/CLAUDE.md.scripts.list" \
        "${repo}/CLAUDE.md.hooks.list"
}

@test "--help prints usage and exits 0" {
  run "$(script check-claude-md-tree.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "Audit"
}

@test "missing CLAUDE.md exits 2" {
  local missing="$(mktemp -d)/CLAUDE.md"
  run "$(script check-claude-md-tree.sh)" "${missing}"
  assert_failure 2
  assert_output --partial "CLAUDE.md not found"
}

@test "missing .claude/ exits 2" {
  local repo
  repo="$(mktemp -d)"
  echo "# fake" > "${repo}/CLAUDE.md"
  run "$(script check-claude-md-tree.sh)" "${repo}/CLAUDE.md"
  assert_failure 2
  assert_output --partial ".claude/ not found"
}

@test "aligned tree exits 0" {
  local repo
  repo="$(mktemp -d)"
  make_fake_repo "${repo}" \
    "commands:audit.md" \
    "scripts:wait-pr-ci.sh" \
    "hooks:check_no_emoji.sh"
  run "$(script check-claude-md-tree.sh)" "${repo}/CLAUDE.md"
  assert_success
  assert_output --partial "aligned"
}

@test "extra file in fs (missing from tree) exits 1 with + entry" {
  local repo
  repo="$(mktemp -d)"
  make_fake_repo "${repo}" \
    "commands:audit.md" \
    "scripts:wait-pr-ci.sh" \
    "hooks:check_no_emoji.sh"
  # Add a file in fs but don't list it
  : > "${repo}/.claude/scripts/new-tool.sh"
  run "$(script check-claude-md-tree.sh)" "${repo}/CLAUDE.md"
  assert_failure 1
  assert_output --partial "+ new-tool.sh"
  assert_output --partial "missing from CLAUDE.md tree"
}

@test "extra entry in tree (missing from fs) exits 1 with - entry" {
  local repo
  repo="$(mktemp -d)"
  make_fake_repo "${repo}" \
    "commands:audit.md" \
    "scripts:wait-pr-ci.sh" \
    "scripts:ghost.sh" \
    "hooks:check_no_emoji.sh"
  # Remove ghost.sh from fs
  rm -f "${repo}/.claude/scripts/ghost.sh"
  run "$(script check-claude-md-tree.sh)" "${repo}/CLAUDE.md"
  assert_failure 1
  assert_output --partial "- ghost.sh"
  assert_output --partial "missing from filesystem"
}

@test "folded subdir (test/) is honoured — no false positive" {
  local repo
  repo="$(mktemp -d)"
  # CLAUDE.md lists `test/` as a folded entry; fs has the subdir but nothing else.
  make_fake_repo "${repo}" \
    "commands:audit.md" \
    "scripts:wait-pr-ci.sh" \
    "hooks:check_no_emoji.sh" \
    "hooks:test/"
  # Drop a deeply nested file inside test/ — should NOT be picked up
  echo "@test 'x' { :; }" > "${repo}/.claude/hooks/test/foo.bats"
  run "$(script check-claude-md-tree.sh)" "${repo}/CLAUDE.md"
  assert_success
  assert_output --partial "aligned"
}

@test "drift in two dirs reports both" {
  local repo
  repo="$(mktemp -d)"
  make_fake_repo "${repo}" \
    "commands:audit.md" \
    "scripts:wait-pr-ci.sh" \
    "hooks:check_no_emoji.sh"
  : > "${repo}/.claude/scripts/added-script.sh"
  : > "${repo}/.claude/hooks/added-hook.sh"
  run "$(script check-claude-md-tree.sh)" "${repo}/CLAUDE.md"
  assert_failure 1
  assert_output --partial "scripts/"
  assert_output --partial "+ added-script.sh"
  assert_output --partial "hooks/"
  assert_output --partial "+ added-hook.sh"
}
