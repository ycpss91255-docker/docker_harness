#!/usr/bin/env bats

# Covers .claude/scripts/ci-and-stamp.sh (refs #208) — runs the repo's
# full CI mirror and, on green, writes the local-ci-pass marker that
# enforce_local_full_ci_before_pr.sh checks. Detection is by marker
# file (.claude/test/ci.sh -> docker_harness `.claude/test/ci.sh check`;
# root justfile + .base/ subtree -> downstream `just build test`;
# root justfile, no .base/ -> base `just test` + `just test lint` +
# `just test go`;
# none -> no stamp, fail-open notice). Detection order matters: the
# downstream `.base/` check precedes the base check (both have a root
# justfile; the .base/ subtree is what a consumer repo vendors). Refs #220.
#
# The docker_harness runner is a stub `.claude/test/ci.sh` exiting
# ${STUB_RC:-0} (ci-and-stamp invokes it directly); the base/downstream
# `just` runner is a PATH shim exiting ${STUB_RC:-0}. No real docker /
# just is needed.
#
# The marker is a green light another tool consumes, so exit status and
# marker presence must be mutually exclusive by construction: exit 0 IFF
# a marker for HEAD exists afterwards. A red run therefore also has to
# REMOVE a marker an earlier green run left on the same sha, and a green
# run that cannot write its marker has to report red.

load '../lib/test_helper'

setup() {
  STUB_DIR="$(mktemp -d)"
  REPO="$(mktemp -d)"
  git -C "${REPO}" init -q -b main
  git -C "${REPO}" config user.email t@t
  git -C "${REPO}" config user.name t
  echo x > "${REPO}/f"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m init
}

teardown() {
  rm -rf "${STUB_DIR}" "${REPO}"
}

# stub_cmd <name> — install a PATH shim that exits ${STUB_RC:-0}.
stub_cmd() {
  printf '#!/usr/bin/env bash\nexit ${STUB_RC:-0}\n' > "${STUB_DIR}/$1"
  chmod +x "${STUB_DIR}/$1"
}

marker() { echo "${REPO}/.claude/state/local-ci-pass/$(git -C "${REPO}" rev-parse HEAD).ok"; }

# stub_harness_ci — install the docker_harness-style runner (a
# `.claude/test/ci.sh` exiting ${STUB_RC:-0}) in the fixture repo.
stub_harness_ci() {
  mkdir -p "${REPO}/.claude/test"
  printf '#!/usr/bin/env bash\nexit ${STUB_RC:-0}\n' > "${REPO}/.claude/test/ci.sh"
  chmod +x "${REPO}/.claude/test/ci.sh"
}

# seed_base_go_repo -- a base-style fixture (root justfile, no .base/) whose
# ci-rollup requires config-gen, the job base's `just test go` backs
# (refs base#1474). No actionlint pin, so actionlint is not required and no
# docker is needed.
seed_base_go_repo() {
  echo 'test:' > "${REPO}/justfile"
  mkdir -p "${REPO}/.github/workflows"
  printf 'jobs:\n  ci-rollup:\n    needs: [bats-fragile, config-gen]\n    if: always()\n' \
    > "${REPO}/.github/workflows/self-test.yaml"
}

# stub_just_argv -- a `just` PATH shim that appends its argv to
# ${STUB_DIR}/just.argv and exits 1 when its argv equals ${STUB_FAIL:-}
# (e.g. STUB_FAIL='test lint'), 0 otherwise. One shim serves the green run
# and a red run at each position of the base recipe chain (refs base#1474).
stub_just_argv() {
  cat > "${STUB_DIR}/just" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_DIR}/just.argv"
if [[ -n "${STUB_FAIL:-}" && "$*" == "${STUB_FAIL}" ]]; then exit 1; fi
exit 0
SHIM
  chmod +x "${STUB_DIR}/just"
}

# assert_base_red_stops_at <failing argv> <expected argv lines...> -- seed the
# base go fixture plus a stale marker for HEAD, make the recipe named by the
# first argument fail, run the stamp, then require: non-zero exit, no marker
# for HEAD, and a just argv log equal to the remaining arguments exactly (the
# chain stops at the first red recipe: nothing after it runs) (refs base#1474).
assert_base_red_stops_at() {
  local fail="$1"; shift
  seed_base_go_repo
  stub_just_argv
  mkdir -p "${REPO}/.claude/state/local-ci-pass"
  : > "$(marker)"
  PATH="${STUB_DIR}:${PATH}" STUB_DIR="${STUB_DIR}" STUB_FAIL="${fail}" \
    run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_failure
  [[ ! -f "$(marker)" ]] || { echo "a red '${fail}' must leave no marker"; return 1; }
  local want got
  want="$(printf '%s\n' "$@")"
  got="$(cat "${STUB_DIR}/just.argv" 2>/dev/null || true)"
  [[ "${got}" == "${want}" ]] \
    || { echo "just argv after red '${fail}': want [${want}] got [${got}]"; return 1; }
}

@test "docker_harness-style (.claude/test/ci.sh) green -> stamps marker" {
  mkdir -p "${REPO}/.claude/test"
  printf '#!/usr/bin/env bash\nexit ${STUB_RC:-0}\n' > "${REPO}/.claude/test/ci.sh"
  chmod +x "${REPO}/.claude/test/ci.sh"
  PATH="${STUB_DIR}:${PATH}" STUB_RC=0 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success
  [[ -f "$(marker)" ]] || { echo "marker not written: $(marker)"; return 1; }
}

@test "CI command non-zero -> NO marker, propagates failure" {
  mkdir -p "${REPO}/.claude/test"
  printf '#!/usr/bin/env bash\nexit ${STUB_RC:-0}\n' > "${REPO}/.claude/test/ci.sh"
  chmod +x "${REPO}/.claude/test/ci.sh"
  PATH="${STUB_DIR}:${PATH}" STUB_RC=1 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_failure
  [[ ! -f "$(marker)" ]] || { echo "marker should NOT exist on CI failure"; return 1; }
}

@test "base-style (root justfile, no .base) green -> runs just test + stamps" {
  echo 'test:' > "${REPO}/justfile"
  stub_cmd just
  PATH="${STUB_DIR}:${PATH}" STUB_RC=0 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success
  [[ -f "$(marker)" ]] || { echo "marker not written for base-style"; return 1; }
}

@test "downstream (root justfile + .base subtree) green -> runs just build test + stamps" {
  echo 'build *args:' > "${REPO}/justfile"
  mkdir -p "${REPO}/.base"
  stub_cmd just
  PATH="${STUB_DIR}:${PATH}" STUB_RC=0 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success
  [[ -f "$(marker)" ]] || { echo "marker not written for downstream"; return 1; }
}

@test "no CI mechanism -> no stamp, exit 0, notice" {
  PATH="${STUB_DIR}:${PATH}" run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success
  [[ ! -f "$(marker)" ]] || { echo "should not stamp a no-CI repo"; return 1; }
  assert_output --partial "no_ci_mechanism"
}

@test "marker filename is the exact HEAD sha" {
  mkdir -p "${REPO}/.claude/test"
  printf '#!/usr/bin/env bash\nexit ${STUB_RC:-0}\n' > "${REPO}/.claude/test/ci.sh"
  chmod +x "${REPO}/.claude/test/ci.sh"
  local sha; sha="$(git -C "${REPO}" rev-parse HEAD)"
  PATH="${STUB_DIR}:${PATH}" STUB_RC=0 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success
  [[ -f "${REPO}/.claude/state/local-ci-pass/${sha}.ok" ]] || { echo "marker not keyed by HEAD sha"; return 1; }
}

@test "green run writes exactly one marker" {
  stub_harness_ci
  PATH="${STUB_DIR}:${PATH}" STUB_RC=0 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success
  local n
  n="$(find "${REPO}/.claude/state/local-ci-pass" -name '*.ok' | wc -l)"
  [[ "${n}" -eq 1 ]] || { echo "expected exactly 1 marker, found ${n}"; return 1; }
}

@test "failing run REMOVES a stale marker for the same HEAD" {
  stub_harness_ci
  mkdir -p "${REPO}/.claude/state/local-ci-pass"
  : > "$(marker)"
  PATH="${STUB_DIR}:${PATH}" STUB_RC=1 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_failure
  [[ ! -f "$(marker)" ]] || { echo "stale green survived a red run on the same sha"; return 1; }
}

@test "failing run keeps markers belonging to other shas" {
  stub_harness_ci
  mkdir -p "${REPO}/.claude/state/local-ci-pass"
  local other="${REPO}/.claude/state/local-ci-pass/0000000000000000000000000000000000000000.ok"
  : > "${other}"
  : > "$(marker)"
  PATH="${STUB_DIR}:${PATH}" STUB_RC=1 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_failure
  [[ ! -f "$(marker)" ]] || { echo "HEAD marker should be removed"; return 1; }
  [[ -f "${other}" ]] || { echo "unrelated sha marker should be left alone"; return 1; }
}

@test "green run whose marker cannot be written exits non-zero" {
  stub_harness_ci
  # A regular file where the marker directory belongs makes both the
  # mkdir -p and the marker write fail.
  mkdir -p "${REPO}/.claude/state"
  : > "${REPO}/.claude/state/local-ci-pass"
  PATH="${STUB_DIR}:${PATH}" STUB_RC=0 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_failure
  assert_output --partial "marker_write_failed"
  [[ ! -f "$(marker)" ]] || { echo "no marker can exist when the write failed"; return 1; }
}

@test "base-style mirror runs just test go and attests config-gen (refs base#1474)" {
  seed_base_go_repo
  stub_just_argv
  PATH="${STUB_DIR}:${PATH}" STUB_DIR="${STUB_DIR}" LOG_FORMAT=json \
    run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success
  [[ -f "$(marker)" ]] || { echo "marker not written: $(marker)"; return 1; }
  local n
  n="$(grep -cx 'attested config-gen' "$(marker)" || true)"
  [[ "${n}" -eq 1 ]] || { echo "expected one 'attested config-gen' line, got ${n}:"; cat "$(marker)"; return 1; }
  ! grep -q '^excluded config-gen' "$(marker)" \
    || { echo "config-gen must be attested, not excluded"; cat "$(marker)"; return 1; }
  local want got
  want="$(printf 'test\ntest lint\ntest go')"
  got="$(cat "${STUB_DIR}/just.argv" 2>/dev/null || true)"
  [[ "${got}" == "${want}" ]] \
    || { echo "just argv: want [${want}] got [${got}]"; return 1; }
  # The whole mirror field, not a substring: a dropped or stale command fails.
  got="$(sed -n 's/^# mirror  //p' "$(marker)")"
  [[ "${got}" == "actionlint + just test + just test lint + just test go" ]] \
    || { echo "marker mirror field: got [${got}]"; cat "$(marker)"; return 1; }
  # The logged ci_start event: exactly one, kind=base, the full command chain.
  got="$(printf '%s\n' "${output}" \
    | jq -Rr 'fromjson? | select(.body == "ci_start") | "\(.attributes.kind)|\(.attributes.cmd)"')"
  [[ "${got}" == "base|just test && just test lint && just test go" ]] \
    || { echo "ci_start events: got [${got}]"; echo "${output}"; return 1; }
}

@test "a red just test stops the base chain and leaves no marker (refs base#1474)" {
  assert_base_red_stops_at 'test' 'test'
}

@test "a red just test lint stops the base chain and leaves no marker (refs base#1474)" {
  assert_base_red_stops_at 'test lint' 'test' 'test lint'
}

@test "a red just test go fails the stamp and leaves no marker (refs base#1474)" {
  assert_base_red_stops_at 'test go' 'test' 'test lint' 'test go'
}
