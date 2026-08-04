#!/usr/bin/env bats

# .claude/test/ci.sh pulls third-party tool images (hadolint) straight from
# a registry. A floating tag (`:latest`, `:latest-alpine`) makes the gate
# depend on whatever upstream published most recently, so an upstream
# release can turn `main` red with no commit in this repo -- exactly what
# hadolint 2.15 did by adding DL3066 (refs #263). Every externally pulled
# tool image must therefore carry an explicit version tag, matching the way
# base pins `rhysd/actionlint:1.7.7`. This spec is a lexical guard so a
# future "tidy-up" back to `latest` fails CI instead of CI failing later,
# attached to some unrelated PR.

load '../lib/test_helper'

# Resolve the repo root from HOOKS_DIR (= <root>/.claude/hooks).
repo_root() {
  cd "${HOOKS_DIR}/../.." && pwd
}

ci_sh() {
  echo "$(repo_root)/.claude/test/ci.sh"
}

@test "HADOLINT_IMAGE pins an explicit hadolint version" {
  local def
  def="$(grep -E "^readonly HADOLINT_IMAGE=" "$(ci_sh)")" || {
    echo "HADOLINT_IMAGE not defined in ci.sh" >&2; return 1; }
  echo "${def}" | grep -qE "hadolint/hadolint:v[0-9]+\.[0-9]+\.[0-9]+" \
    || { echo "HADOLINT_IMAGE is not pinned to vX.Y.Z: ${def}" >&2; return 1; }
}

@test "no externally pulled tool image in ci.sh uses a floating tag" {
  # Externally pulled = the image reference names a registry namespace
  # (contains a '/'); the locally built IMAGE constant is exempt because
  # ci.sh builds it from .claude/test/Dockerfile in the same run.
  local offenders
  offenders="$(grep -nE "^readonly [A-Z_]*IMAGE=" "$(ci_sh)" \
    | grep -F '/' \
    | grep -E ":latest|:[a-z0-9]+-latest|latest-[a-z0-9]+'" || true)"
  [ -z "${offenders}" ] || {
    echo "ci.sh pulls a floating tool image tag:" >&2
    echo "${offenders}" >&2
    return 1
  }
}

@test "the HADOLINT_IMAGE pin carries a comment explaining why it is pinned" {
  # A bare pin invites a "helpful" bump back to latest; the reason has to
  # sit next to the constant.
  local ln preamble
  ln="$(grep -nE "^readonly HADOLINT_IMAGE=" "$(ci_sh)" | cut -d: -f1)"
  [ -n "${ln}" ] || { echo "HADOLINT_IMAGE not defined in ci.sh" >&2; return 1; }
  preamble="$(sed -n "$(( ln > 8 ? ln - 8 : 1 )),$(( ln - 1 ))p" "$(ci_sh)" \
    | grep -E "^#")"
  echo "${preamble}" | grep -qiE "pin" \
    || { echo "no why-comment above HADOLINT_IMAGE" >&2; return 1; }
}
