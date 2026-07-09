#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  GH_STUB_DIR="$(mktemp -d)"
  export PATH="${GH_STUB_DIR}:${PATH}"
  # Isolate $HOME so the script's event-log writes to
  # `~/.claude/log/wait-pr-ci-events.log` stay inside the tempdir.
  HOME_DIR="$(mktemp -d)"
  export HOME="${HOME_DIR}"
}

teardown() {
  rm -rf "${GH_STUB_DIR}" "${HOME_DIR}"
}

# stub_gh <json> — install a `gh` shim that always echoes the given JSON
# on stdout regardless of arguments.
stub_gh() {
  local json="$1"
  printf '#!/usr/bin/env bash\nprintf %%s %q\n' "${json}" > "${GH_STUB_DIR}/gh"
  chmod +x "${GH_STUB_DIR}/gh"
}

@test "--help prints usage and exits 0" {
  run "$(script wait-pr-ci-batch.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "<repo>:<pr>"
}

@test "no pairs exits 2" {
  run "$(script wait-pr-ci-batch.sh)"
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"reason":"no-pairs"'
}

@test "bad pair (no colon) exits 2" {
  run "$(script wait-pr-ci-batch.sh)" not-a-pair
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"reason":"bad-format"'
}

@test "non-numeric PR exits 2" {
  run "$(script wait-pr-ci-batch.sh)" ai_agent:abc
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"reason":"non-numeric-pr"'
}

@test "unknown flag exits 2" {
  run "$(script wait-pr-ci-batch.sh)" --bogus ai_agent:1
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
}

@test "all-pass single short-form pair exits 0 with ALL_DONE" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ycpss91255-docker/ai_agent#1: checks=all-pass mergeable=MERGEABLE"
  assert_output --partial "ALL_DONE"
}

@test "full owner/repo form is accepted (no prefix added)" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" other-org/repo:5 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "other-org/repo#5"
  refute_output --partial "ycpss91255-docker/other-org"
}

@test "--owner overrides default for short form" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" --owner my-org repo-a:7 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "my-org/repo-a#7"
}

@test "any FAILURE check exits 1 with FAIL <repo>#<pr>" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"}]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:9 --interval 0 --max-iterations 3
  assert_failure 1
  assert_output --partial "checks=FAIL"
  assert_output --partial "FAIL ycpss91255-docker/ai_agent#9"
}

@test "mixed SUCCESS+SKIPPED rollup hits ALL_DONE" {
  # refs ycpss91255-docker/docker_harness#86 -- sibling of wait-pr-ci.sh.
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"Integration","status":"COMPLETED","conclusion":"SKIPPED"}]}'
  run "$(script wait-pr-ci-batch.sh)" a/b:1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "a/b#1: checks=all-pass mergeable=MERGEABLE"
  assert_output --partial "ALL_DONE"
}

@test "multiple pairs all-pass + MERGEABLE exits 0" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 claude_code:2 codex_cli:3 \
        --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ai_agent#1"
  assert_output --partial "claude_code#2"
  assert_output --partial "codex_cli#3"
  assert_output --partial "ALL_DONE"
}

@test "custom --check-filter narrows to a non-default check name" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"call-docker-build / docker-build","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" \
        --check-filter '.name=="call-docker-build / docker-build"' \
        ai_agent:1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "checks=all-pass"
}

@test "max-iterations exits 124 when stuck pending" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"PENDING"}]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 --interval 0 --max-iterations 2
  assert_failure 124
}

@test "no matching checks counts as no-checks (not all-pass) and loops" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 --interval 0 --max-iterations 2
  assert_failure 124
  assert_output --partial "checks=no-checks"
}

@test "all-pass but UNKNOWN mergeable does not exit ALL_DONE" {
  stub_gh '{"mergeable":"UNKNOWN","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 --interval 0 --max-iterations 2
  assert_failure 124
  assert_output --partial "checks=all-pass mergeable=UNKNOWN"
}

# stub_gh_per_repo — install a `gh` shim that returns repo-specific JSON.
# Reads `--repo <owner>/<repo>` from gh args and looks up an env var
# named STUB_<short_repo>, where <short_repo> is the basename uppercased
# with hyphens replaced by underscores. Falls back to STUB_DEFAULT.
stub_gh_per_repo() {
  cat > "${GH_STUB_DIR}/gh" <<'STUB_EOF'
#!/usr/bin/env bash
repo=""
while (( $# > 0 )); do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) shift ;;
  esac
done
short="${repo##*/}"
key="STUB_$(printf '%s' "${short}" | tr 'a-z-' 'A-Z_')"
val="${!key:-}"
if [[ -n "${val}" ]]; then
  printf '%s' "${val}"
else
  printf '%s' "${STUB_DEFAULT:-{\}}"
fi
STUB_EOF
  chmod +x "${GH_STUB_DIR}/gh"
}

@test "per-repo --check-filter <repo>=<expr> applies only to that repo" {
  stub_gh_per_repo
  export STUB_AI_AGENT='{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"call-docker-build / docker-build","conclusion":"SUCCESS"}]}'
  export STUB_ROS_DISTRO='{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"ci-passed","conclusion":"SUCCESS"},{"name":"call-docker-build / docker-build","conclusion":"FAILURE"}]}'
  run "$(script wait-pr-ci-batch.sh)" \
        --check-filter '.name=="call-docker-build / docker-build"' \
        --check-filter 'ros_distro=.name=="ci-passed"' \
        ai_agent:1 ros_distro:3 \
        --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ai_agent#1: checks=all-pass"
  assert_output --partial "ros_distro#3: checks=all-pass"
  assert_output --partial "ALL_DONE"
}

@test "per-repo filter overrides default for one repo, others fall back" {
  stub_gh_per_repo
  export STUB_DEFAULT='{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  export STUB_ROS2_DISTRO='{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"ci-passed","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" \
        --check-filter 'ros2_distro=.name=="ci-passed"' \
        ai_agent:1 ros2_distro:3 \
        --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ai_agent#1: checks=all-pass"
  assert_output --partial "ros2_distro#3: checks=all-pass"
  assert_output --partial "ALL_DONE"
}

@test "per-repo filter accepts full owner/repo key form" {
  stub_gh_per_repo
  export STUB_REPO_X='{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"ci-summary","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" \
        --check-filter 'other-org/repo-x=.name=="ci-summary"' \
        other-org/repo-x:9 \
        --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "other-org/repo-x#9: checks=all-pass"
  assert_output --partial "ALL_DONE"
}

@test "global --check-filter (no repo prefix) still works as before" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"call-docker-build / docker-build","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" \
        --check-filter '.name=="call-docker-build / docker-build"' \
        ai_agent:1 claude_code:2 \
        --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ai_agent#1: checks=all-pass"
  assert_output --partial "claude_code#2: checks=all-pass"
  assert_output --partial "ALL_DONE"
}

@test "per-repo filter with no matching check counts as no-checks" {
  stub_gh_per_repo
  export STUB_ROS_DISTRO='{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"call-docker-build / docker-build","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" \
        --check-filter 'ros_distro=.name=="ci-passed"' \
        ros_distro:3 \
        --interval 0 --max-iterations 2
  assert_failure 124
  assert_output --partial "ros_distro#3: checks=no-checks"
}

@test "duplicate --check-filter for same repo: last one wins" {
  stub_gh_per_repo
  export STUB_ROS_DISTRO='{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"ci-passed","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" \
        --check-filter 'ros_distro=.name=="WRONG"' \
        --check-filter 'ros_distro=.name=="ci-passed"' \
        ros_distro:3 \
        --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ros_distro#3: checks=all-pass"
  assert_output --partial "ALL_DONE"
}

# --min-checks / status guard regressions, mirroring wait_pr_ci_spec.bats.

@test "--min-checks 2 with only 1 matching SUCCESS stays pending (subset rollup race)" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"Integration E2E","status":"COMPLETED","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" template:1 \
        --min-checks 2 --interval 0 --max-iterations 2
  assert_failure 124
  assert_output --partial "checks=pending"
  refute_output --partial "checks=all-pass"
}

@test "status IN_PROGRESS blocks all-pass (status guard)" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"IN_PROGRESS","conclusion":""}]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 --interval 0 --max-iterations 2
  assert_failure 124
  assert_output --partial "checks=pending"
  refute_output --partial "checks=all-pass"
}

@test "per-repo --min-checks <repo>=<N> applies only to that repo" {
  # template repo needs 2 checks; ai_agent (single-distro container) needs 1.
  # ai_agent's 1 SUCCESS should still all-pass while template stays pending.
  stub_gh_per_repo
  export STUB_AI_AGENT='{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"call-docker-build / docker-build","status":"COMPLETED","conclusion":"SUCCESS"}]}'
  export STUB_TEMPLATE='{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"Integration E2E","status":"COMPLETED","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" \
        --check-filter '.name=="call-docker-build / docker-build"' \
        --check-filter 'template=.name=="test" or (.name|startswith("Integration"))' \
        --min-checks 'template=2' \
        ai_agent:1 template:5 \
        --interval 0 --max-iterations 2
  assert_failure 124
  assert_output --partial "ai_agent#1: checks=all-pass"
  assert_output --partial "template#5: checks=pending"
  refute_output --partial "ALL_DONE"
}

@test "--min-checks default 1 preserves backwards-compatible behaviour" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ALL_DONE"
}

@test "--min-checks non-integer exits 2" {
  run "$(script wait-pr-ci-batch.sh)" --min-checks foo ai_agent:1
  assert_failure 2
  assert_output --partial "--min-checks"
}

@test "--min-checks <repo>=<non-int> exits 2" {
  run "$(script wait-pr-ci-batch.sh)" --min-checks 'template=foo' template:1
  assert_failure 2
  assert_output --partial "--min-checks"
}

# Stale-rollup guards (refs ycpss91255-docker/docker_harness#60). Mirror
# the wait-pr-ci.sh tests; the batch script must apply the same demotion
# rules per-pair so one stale PR doesn't abort the batch.

# stub_gh_seq <json1> [<json2> ...] — sequential per-call response.
# Same as in wait_pr_ci_spec.bats but local copy so the batch suite
# stays self-contained.
stub_gh_seq() {
  local i=0
  local json
  for json in "$@"; do
    i=$((i + 1))
    printf '%s' "${json}" > "${GH_STUB_DIR}/resp_${i}.json"
  done
  local last="${i}"
  cat > "${GH_STUB_DIR}/gh" <<STUB_EOF
#!/usr/bin/env bash
cf="${GH_STUB_DIR}/call_count"
[[ -f "\${cf}" ]] || echo 0 > "\${cf}"
n=\$(<"\${cf}")
n=\$((n + 1))
echo "\${n}" > "\${cf}"
last=${last}
(( n > last )) && n=\${last}
cat "${GH_STUB_DIR}/resp_\${n}.json"
STUB_EOF
  chmod +x "${GH_STUB_DIR}/gh"
}

@test "all-pass with completedAt predating watch start → pending (batch)" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"1970-01-01T00:00:00Z"}],"headRefOid":"a000000aaaaaaaa"}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 --interval 0 --max-iterations 2
  assert_failure 124
  assert_output --partial "ai_agent#1: checks=pending"
  refute_output --partial "ALL_DONE"
}

@test "headRefOid change between polls emits [head-moved] (batch)" {
  stub_gh_seq \
    '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"IN_PROGRESS","conclusion":""}],"headRefOid":"a000000aaaaaaaa"}' \
    '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2099-01-01T00:00:00Z"}],"headRefOid":"b111111bbbbbbbb"}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 --interval 0 --max-iterations 2
  assert_failure 124
  assert_output --partial "[head-moved] ycpss91255-docker/ai_agent#1 a000000..b111111"
  refute_output --partial "ALL_DONE"
}

@test "stable headRefOid across polls preserves ALL_DONE path (batch)" {
  stub_gh_seq \
    '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2099-01-01T00:00:00Z"}],"headRefOid":"a000000aaaaaaaa"}' \
    '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2099-01-01T00:00:00Z"}],"headRefOid":"a000000aaaaaaaa"}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ALL_DONE"
  refute_output --partial "[head-moved]"
}

@test "JSON without headRefOid preserves backwards-compatible behaviour (batch)" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ALL_DONE"
  refute_output --partial "[head-moved]"
}

@test "all pairs state=MERGED exits 0 with ALL_DONE (batch)" {
  # refs ycpss91255-docker/docker_harness#113.
  stub_gh '{"state":"MERGED","mergeable":"UNKNOWN","statusCheckRollup":[{"name":"call-docker-build / docker-build","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 claude_code:2 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ycpss91255-docker/ai_agent#1: state=MERGED (auto-merge completed)"
  assert_output --partial "ycpss91255-docker/claude_code#2: state=MERGED (auto-merge completed)"
  assert_output --partial "ALL_DONE"
}

@test "one pair state=CLOSED in batch exits 1 with FAIL (batch)" {
  stub_gh '{"state":"CLOSED","mergeable":"UNKNOWN","statusCheckRollup":[{"name":"call-docker-build / docker-build","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 --interval 0 --max-iterations 3
  assert_failure 1
  assert_output --partial "ycpss91255-docker/ai_agent#1: state=CLOSED without merge"
  assert_output --partial "FAIL ycpss91255-docker/ai_agent#1 (state=CLOSED without merge)"
}

@test "absent .state field preserves backwards-compatible behaviour (batch)" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"call-docker-build / docker-build","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 --interval 0 --max-iterations 3 \
    --check-filter '.name=="call-docker-build / docker-build"'
  assert_success
  assert_output --partial "ycpss91255-docker/ai_agent#1: checks=all-pass mergeable=MERGEABLE"
  assert_output --partial "ALL_DONE"
  refute_output --partial "state=MERGED"
}

# ---- event-log emit (refs #175 Phase 1) ----
#
# Aggregate: ONE JSON object per script invocation (NOT per pair). The
# exit_reason rolls up across pairs (any FAIL -> FAIL, all-pass -> ALL_DONE).
# Phase 2 reads `pairs` to slice batch invocations by repo / pair count.

@test "ALL_DONE batch appends one aggregate JSON event line with pairs[]" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:1 claude_code:2 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ALL_DONE"
  local log="${HOME}/.claude/log/wait-pr-ci-events.log"
  [[ -f "${log}" ]] || { echo "log not at ${log}"; return 1; }
  local lines
  lines="$(wc -l < "${log}")"
  [[ "${lines}" == "1" ]] || { echo "want 1 line, got ${lines}"; cat "${log}"; return 1; }
  jq -e '
    .script == "wait-pr-ci-batch.sh"
    and .exit_reason == "ALL_DONE"
    and .pairs == [
      {"repo":"ycpss91255-docker/ai_agent","pr":1},
      {"repo":"ycpss91255-docker/claude_code","pr":2}
    ]
    and (.iterations | type) == "number"
    and (.elapsed_sec | type) == "number"
    and (.head_moves | type) == "number"
    and (.ts | type) == "string"
  ' "${log}" >/dev/null \
    || { echo "schema mismatch:"; cat "${log}"; return 1; }
}

@test "FAIL batch appends event line with exit_reason=FAIL" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"}]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:3 --interval 0 --max-iterations 3
  assert_failure 1
  local log="${HOME}/.claude/log/wait-pr-ci-events.log"
  [[ -f "${log}" ]] || { echo "log not at ${log}"; return 1; }
  jq -e '.exit_reason == "FAIL" and .pairs == [{"repo":"ycpss91255-docker/ai_agent","pr":3}]' \
    "${log}" >/dev/null \
    || { cat "${log}"; return 1; }
}

@test "max-iterations batch appends event line with exit_reason=timeout_max_iter" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"PENDING"}]}'
  run "$(script wait-pr-ci-batch.sh)" ai_agent:5 --interval 0 --max-iterations 2
  assert_equal "${status}" 124
  local log="${HOME}/.claude/log/wait-pr-ci-events.log"
  [[ -f "${log}" ]] || { echo "log not at ${log}"; return 1; }
  jq -e '.exit_reason == "timeout_max_iter" and .iterations == 2' "${log}" >/dev/null \
    || { cat "${log}"; return 1; }
}
