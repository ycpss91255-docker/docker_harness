#!/usr/bin/env bats

# Covers the local-CI attestation's completeness contract (refs #272).
#
# `enforce_local_full_ci_before_pr.sh` DENIES `gh pr create` until
# `.claude/state/local-ci-pass/<sha>.ok` exists, so that marker is read as
# "GH CI will pass". For a `base` checkout the mirror ran
# `just test && just test lint`, which covers 6 of the 13 jobs `ci-rollup`
# lists in its `needs:` -- and nothing compared the two sets, so a required
# job could (and did) fail on a branch the marker had attested.
#
# The fix is the `lint-static` completeness-guard shape: the required set is
# DERIVED from `ci-rollup`'s `needs:` at stamp time, every derived job must be
# classified either "attested" (the local mirror really runs it) or "excluded"
# (named, with a reason), and a job in neither aborts the stamp instead of
# falling silently outside the attestation.

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

# stub_cmd <name> -- PATH shim exiting ${STUB_RC:-0}, recording its argv.
# The log path is interpolated at GENERATION time: a literal `$1` inside the
# generated script would be the shim's own first argument at run time
# (`docker run ...` -> `run.argv`), not the command's name.
stub_cmd() {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit ${STUB_RC:-0}\n' \
    "${STUB_DIR}/$1.argv" > "${STUB_DIR}/$1"
  chmod +x "${STUB_DIR}/$1"
}

marker() { echo "${REPO}/.claude/state/local-ci-pass/$(git -C "${REPO}" rev-parse HEAD).ok"; }

# The jobs base's ci-rollup really requires, as of this spec being written.
# The point of the guard under test is that ci-and-stamp reads them out of
# the workflow rather than out of a table like this one; the list is here
# only to build the fixture and to assert the parser agrees with it.
readonly ROLLUP_NEEDS='actionlint, classify, shellcheck, doc-counts, lint-static, hadolint, bats-fragile, bats-integration, coverage, coverage-gate, acceptance, system, worker-selftest'

# seed_base_repo -- make ${REPO} look like a `base` checkout: root justfile,
# no .base/ subtree, and a self-test.yaml whose ci-rollup carries the real
# 13-job needs list plus the pinned actionlint invocation.
seed_base_repo() {
  echo 'test:' > "${REPO}/justfile"
  mkdir -p "${REPO}/.github/workflows"
  {
    printf 'jobs:\n'
    printf '  actionlint:\n'
    printf '    runs-on: ubuntu-latest\n'
    printf '    steps:\n'
    printf '      - name: Run actionlint via Docker\n'
    printf '        run: |\n'
    printf '          docker run --rm \\\n'
    printf '            -v "${GITHUB_WORKSPACE}:/repo:ro" \\\n'
    printf '            -w /repo \\\n'
    printf '            rhysd/actionlint:1.7.7 \\\n'
    printf '            -color \\\n'
    printf "            -ignore 'property \"job_workflow_sha\" is not defined'\n"
    printf '  ci-rollup:\n'
    printf '    needs: [%s]\n' "${ROLLUP_NEEDS}"
    printf '    if: always()\n'
  } > "${REPO}/.github/workflows/self-test.yaml"
}

@test "ci_required_jobs derives ci-rollup's needs from the workflow" {
  seed_base_repo
  run bash -c "source '${SCRIPTS_DIR}/lib/ci-required-jobs.sh'; \
               ci_required_jobs '${REPO}/.github/workflows/self-test.yaml'"
  assert_success
  local job
  for job in actionlint classify shellcheck doc-counts lint-static hadolint \
             bats-fragile bats-integration coverage coverage-gate acceptance \
             system worker-selftest; do
    assert_line "${job}"
  done
  [ "${#lines[@]}" -eq 13 ] \
    || fail "expected 13 required jobs, got ${#lines[@]}: ${output}"
}

@test "ci_required_jobs is silent + non-zero when the workflow has no rollup" {
  printf 'jobs:\n  test:\n    runs-on: ubuntu-latest\n' > "${REPO}/wf.yaml"
  run bash -c "source '${SCRIPTS_DIR}/lib/ci-required-jobs.sh'; \
               ci_required_jobs '${REPO}/wf.yaml'"
  assert_failure
  assert_output ''
}

@test "base stamp classifies EVERY job ci-rollup requires (refs #272)" {
  # The regression this issue is about: the marker attested a set nobody
  # had compared against ci-rollup's `needs:`. Every derived job must now
  # appear in the marker -- either as attested or as a named exclusion.
  seed_base_repo
  stub_cmd just
  stub_cmd docker
  PATH="${STUB_DIR}:${PATH}" STUB_RC=0 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success

  local body job
  body="$(cat "$(marker)")"
  for job in actionlint classify shellcheck doc-counts lint-static hadolint \
             bats-fragile bats-integration coverage coverage-gate acceptance \
             system worker-selftest; do
    [[ "${body}" == *"${job}"* ]] \
      || fail "marker does not account for required job '${job}':
${body}"
  done
}

@test "base stamp records the deliberately-excluded jobs with a reason" {
  seed_base_repo
  stub_cmd just
  stub_cmd docker
  PATH="${STUB_DIR}:${PATH}" STUB_RC=0 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success

  local body
  body="$(cat "$(marker)")"
  [[ "${body}" == *excluded* ]] \
    || fail "marker states no exclusions, so it still reads as 'GH CI will pass':
${body}"
  local job
  for job in coverage coverage-gate acceptance system worker-selftest; do
    grep -qE "^excluded[[:space:]]+${job}[[:space:]]+\S" <<< "${body}" \
      || fail "excluded job '${job}' carries no reason in the marker:
${body}"
  done
}

@test "a required job in neither list aborts the stamp instead of passing" {
  # The anti-rot half: adding a job to ci-rollup's needs without teaching the
  # mirror about it must fail HERE, not silently widen the gap the marker hides.
  seed_base_repo
  sed -i "s/needs: \[/needs: [brand-new-gate, /" \
    "${REPO}/.github/workflows/self-test.yaml"
  stub_cmd just
  stub_cmd docker
  PATH="${STUB_DIR}:${PATH}" STUB_RC=0 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_failure
  assert_output --partial 'brand-new-gate'
  [[ ! -f "$(marker)" ]] \
    || fail "stamped despite an unclassified required job"
}

@test "base mirror runs actionlint at the pin the workflow declares" {
  # actionlint was one of the three checks that went red past a green marker.
  # It is "a container away", so the mirror runs it -- at the workflow's own
  # pin, derived, so a version bump in CI cannot leave the mirror behind.
  seed_base_repo
  stub_cmd just
  stub_cmd docker
  PATH="${STUB_DIR}:${PATH}" STUB_RC=0 run "$(script ci-and-stamp.sh)" "${REPO}"
  assert_success
  grep -q 'rhysd/actionlint:1.7.7' "${STUB_DIR}/docker.argv" \
    || fail "actionlint not invoked at the workflow's pin:
$(cat "${STUB_DIR}/docker.argv" 2>/dev/null)"
}
