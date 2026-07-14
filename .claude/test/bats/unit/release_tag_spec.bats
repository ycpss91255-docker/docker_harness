#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  REPO="$(mktemp -d)"
  GH_STUB_DIR="$(mktemp -d)"
  export PATH="${GH_STUB_DIR}:${PATH}"

  (
    cd "${REPO}" || exit 1
    git init -q -b main
    git config user.email "t@t"
    git config user.name "t"
    echo init > README.md
    git add -A >/dev/null
    git commit -q -m init
  ) >/dev/null
}

teardown() {
  rm -rf "${REPO}" "${GH_STUB_DIR}"
}

# stub_gh <lines> — install a gh shim that echoes <lines> on stdout
# regardless of args. <lines> contains one --jq filtered output per line
# (e.g. "success\nskipped" → two conclusions).
stub_gh() {
  printf '%s' "$1" > "${GH_STUB_DIR}/canned_output"
  cat > "${GH_STUB_DIR}/gh" <<EOF
#!/usr/bin/env bash
cat "${GH_STUB_DIR}/canned_output"
EOF
  chmod +x "${GH_STUB_DIR}/gh"
}

# seed_tag <tag> [<tag>...] — create lightweight tags in $REPO so
# release-tag.sh's `git tag --list` enumeration sees them.
seed_tag() {
  local t
  for t in "$@"; do
    git -C "${REPO}" tag "${t}"
  done
}

# seed_version <content> — write to $REPO/.version.
seed_version() {
  printf '%s\n' "$1" > "${REPO}/.version"
  ( cd "${REPO}" && git add .version >/dev/null && git commit -q -m "bump .version" )
}

# Helper: run release-tag.sh with cwd in $REPO and additional flags.
# Tests always pass --dry-run unless they want to assert actual tag creation
# (none currently do — we test rule enforcement, not git plumbing).
run_release_tag() {
  cd "${REPO}" && run "$(script release-tag.sh)" --dry-run "$@"
}

# ------------------------------------------------------------------
# Argument validation
# ------------------------------------------------------------------

@test "--help exits 0 and prints usage" {
  run "$(script release-tag.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "release-tag.sh <tag>"
}

@test "missing <tag> exits 2" {
  run "$(script release-tag.sh)" --dry-run
  assert_failure 2
  assert_output --partial "missing <tag>"
}

@test "malformed tag (no v prefix) exits 2" {
  run "$(script release-tag.sh)" --dry-run 1.3.0
  assert_failure 2
  assert_output --partial "unexpected arg"
}

@test "malformed tag (extra suffix) exits 2" {
  run "$(script release-tag.sh)" --dry-run v1.3.0-foo
  assert_failure 2
  assert_output --partial "invalid tag shape"
}

@test "unknown flag exits 2" {
  run "$(script release-tag.sh)" --bogus v1.3.0
  assert_failure 2
  assert_output --partial "unknown flag"
}

@test "duplicate tag arg exits 2" {
  run "$(script release-tag.sh)" --dry-run v1.3.0 v1.3.1
  assert_failure 2
  assert_output --partial "duplicate tag arg"
}

# ------------------------------------------------------------------
# .version integrity (script-side defensive layer)
# ------------------------------------------------------------------

@test "exits 2 when .version mismatches the target tag" {
  seed_version "v0.18.0"
  run_release_tag v0.19.0 -m bump
  assert_failure 2
  assert_output --partial "tag-version mismatch"
  assert_output --partial "v0.18.0"
}

@test "passes when .version matches target tag (Z bump)" {
  seed_version "v0.18.1"
  seed_tag v0.18.0
  run_release_tag v0.18.1 -m fix
  assert_success
  assert_output --partial "[dry-run] would tag"
  assert_output --partial "v0.18.1"
}

@test "no .version file -> rule N/A (Z bump still passes)" {
  seed_tag v0.18.0
  run_release_tag v0.18.1 -m fix
  assert_success
  assert_output --partial "[dry-run]"
}

# ------------------------------------------------------------------
# RC tag itself
# ------------------------------------------------------------------

@test "RC tag itself passes without RC / ACK checks" {
  run_release_tag v1.3.0-rc1 -m rc
  assert_success
  assert_output --partial "[dry-run] would tag"
  assert_output --partial "v1.3.0-rc1"
}

@test "RC tag passes even with no prev tag in repo" {
  # First-ever tag in fresh repo is permitted for RC.
  run_release_tag v0.1.0-rc1 -m rc
  assert_success
  assert_output --partial "[dry-run]"
}

# ------------------------------------------------------------------
# Z bump (Z > 0)
# ------------------------------------------------------------------

@test "Z>0 patch tag passes without RC / ACK" {
  seed_tag v1.3.0
  run_release_tag v1.3.1 -m fix
  assert_success
  assert_output --partial "[dry-run]"
}

@test "Z>>0 still passes (e.g. v1.3.42)" {
  seed_tag v1.3.0
  run_release_tag v1.3.42 -m big-fix
  assert_success
}

# ------------------------------------------------------------------
# Y bump (vX.Y.0 where Y bumped)
# ------------------------------------------------------------------

@test "Y bump blocked with no RC tag in repo" {
  seed_tag v1.2.0
  run_release_tag v1.3.0 -m feat
  assert_failure 1
  assert_output --partial "no RC tag found for v1.3.0"
  assert_output --partial "release-tag.sh v1.3.0-rc1"
}

@test "Y bump passes with RC + all success CI" {
  seed_tag v1.2.0 v1.3.0-rc1
  stub_gh $'success'
  run_release_tag v1.3.0 -m feat
  assert_success
  assert_output --partial "OK: v1.3.0-rc1 CI all success/skipped"
  assert_output --partial "[dry-run]"
}

@test "Y bump passes with RC + mix success/skipped (issue #86 parity)" {
  seed_tag v1.2.0 v1.3.0-rc1
  stub_gh $'success\nskipped\nsuccess'
  run_release_tag v1.3.0 -m feat
  assert_success
  assert_output --partial "OK: v1.3.0-rc1"
}

@test "Y bump blocked with RC + failing CI" {
  seed_tag v1.2.0 v1.3.0-rc1
  stub_gh $'success\nfailure'
  run_release_tag v1.3.0 -m feat
  assert_failure 1
  assert_output --partial "no RC tag with passing CI"
  assert_output --partial "v1.3.0-rc1"
}

@test "Y bump blocked with RC + cancelled CI" {
  seed_tag v1.2.0 v1.3.0-rc1
  stub_gh $'cancelled'
  run_release_tag v1.3.0 -m feat
  assert_failure 1
  assert_output --partial "no RC tag with passing CI"
}

@test "Y bump picks latest passing RC when multiple RCs exist" {
  # rc1 has failure recorded against it, rc2 is clean.
  # Script iterates RCs sort=-v:refname → newest first (rc2).
  seed_tag v1.2.0 v1.3.0-rc1 v1.3.0-rc2
  stub_gh $'success'
  run_release_tag v1.3.0 -m feat
  assert_success
  # Newest RC (rc2) is the one whose CI we queried.
  assert_output --partial "v1.3.0-rc2"
}

# ------------------------------------------------------------------
# X bump (vX.0.0 where X bumped)
# ------------------------------------------------------------------

@test "X bump blocked without ACK env" {
  seed_tag v0.18.0 v1.0.0-rc1
  unset RELEASE_X_BUMP_ACK
  stub_gh $'success'
  run_release_tag v1.0.0 -m major
  assert_failure 1
  assert_output --partial "X bump"
  assert_output --partial "requires explicit user consent"
  assert_output --partial "RELEASE_X_BUMP_ACK=v1.0.0"
}

@test "X bump blocked with ACK value not matching tag literal" {
  seed_tag v0.18.0 v1.0.0-rc1
  stub_gh $'success'
  RELEASE_X_BUMP_ACK="v0.18.0" run_release_tag v1.0.0 -m major
  assert_failure 1
  assert_output --partial "does not match tag"
  assert_output --partial "verbatim"
}

@test "X bump passes with ACK + RC + passing CI" {
  seed_tag v0.18.0 v1.0.0-rc1
  stub_gh $'success'
  RELEASE_X_BUMP_ACK="v1.0.0" run_release_tag v1.0.0 -m major
  assert_success
  assert_output --partial "OK: v1.0.0-rc1"
  assert_output --partial "[dry-run]"
}

@test "X bump blocked even with ACK if RC CI fails" {
  seed_tag v0.18.0 v1.0.0-rc1
  stub_gh $'success\nfailure'
  RELEASE_X_BUMP_ACK="v1.0.0" run_release_tag v1.0.0 -m major
  assert_failure 1
  assert_output --partial "no RC tag with passing CI"
}

@test "X bump blocked with ACK but no RC tag at all" {
  seed_tag v0.18.0
  RELEASE_X_BUMP_ACK="v1.0.0" run_release_tag v1.0.0 -m major
  assert_failure 1
  assert_output --partial "no RC tag found for v1.0.0"
}

# ------------------------------------------------------------------
# Dry-run vs actual
# ------------------------------------------------------------------

@test "--dry-run does not create any tag" {
  seed_tag v1.2.0 v1.3.0-rc1
  stub_gh $'success'
  cd "${REPO}" && run "$(script release-tag.sh)" --dry-run v1.3.0 -m feat
  assert_success
  # No v1.3.0 tag was actually created (only the seed v1.3.0-rc1 + v1.2.0)
  local tags
  tags="$(git -C "${REPO}" tag --list)"
  [[ "${tags}" == *"v1.3.0-rc1"* ]]
  [[ "${tags}" != *"v1.3.0"$'\n'* && "${tags}" != *$'\n'"v1.3.0" ]] || \
    [[ "$(echo "${tags}" | grep -c '^v1.3.0$')" == "0" ]]
}
