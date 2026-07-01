#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  GH_STUB_DIR="$(mktemp -d)"
  export PATH="${GH_STUB_DIR}:${PATH}"
  # Isolate $HOME so the script's `~/.claude/log/wait-pr-ci-events.log`
  # writes stay inside the test tempdir and never touch the developer's
  # real log file. Tests assert on `${HOME}/.claude/log/...`.
  HOME_DIR="$(mktemp -d)"
  export HOME="${HOME_DIR}"
}

teardown() {
  rm -rf "${GH_STUB_DIR}" "${HOME_DIR}"
}

# stub_gh <json> — install a `gh` shim that always echoes the given JSON
# on stdout regardless of arguments. Used to feign `gh pr view` output.
stub_gh() {
  local json="$1"
  printf '#!/usr/bin/env bash\nprintf %%s %q\n' "${json}" > "${GH_STUB_DIR}/gh"
  chmod +x "${GH_STUB_DIR}/gh"
}

# stub_gh_seq <json1> [<json2> ...] — install a `gh` shim that returns
# JSON1 on the first call, JSON2 on the second, etc. After the last
# JSON the stub keeps returning the final element. Each JSON is stored
# in resp_N.json under GH_STUB_DIR; the stub increments a call counter
# in call_count and reads the corresponding file. Used to feign state
# transitions across poll iterations (e.g. force-push between polls).
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

@test "--help prints usage and exits 0" {
  run "$(script wait-pr-ci.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--repo"
  assert_output --partial "--prs"
}

@test "missing --repo exits 2" {
  run "$(script wait-pr-ci.sh)" --prs 1
  assert_failure 2
  assert_output --partial "--repo"
}

@test "missing --prs exits 2" {
  run "$(script wait-pr-ci.sh)" --repo a/b
  assert_failure 2
  assert_output --partial "--prs"
}

@test "unknown arg exits 2" {
  run "$(script wait-pr-ci.sh)" --bogus
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
}

@test "all-pass + MERGEABLE single PR exits 0 with ALL_DONE" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "PR1: checks=all-pass mergeable=MERGEABLE"
  assert_output --partial "ALL_DONE"
}

@test "any FAILURE check exits 1 with FAIL <pr>" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 7 --interval 0 --max-iterations 3
  assert_failure 1
  assert_output --partial "checks=FAIL"
  assert_output --partial "FAIL 7"
}

@test "all-pass + CONFLICTING mergeable exits 1 with update-stale-pr hint" {
  # refs ycpss91255-docker/docker_harness#87 / #221 -- when checks pass but
  # mergeable=CONFLICTING, the resolution is to merge origin/main into the
  # branch (no rebase). Surface as FAIL with the update-stale-pr.sh
  # canonical incantation rather than looping forever on CONFLICTING.
  stub_gh '{"mergeable":"CONFLICTING","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 42 --interval 0 --max-iterations 3
  assert_failure 1
  assert_output --partial "FAIL 42 (mergeable=CONFLICTING)"
  assert_output --partial "update-stale-pr.sh 42 --repo a/b"
}

@test "mixed SUCCESS+SKIPPED rollup hits ALL_DONE" {
  # refs ycpss91255-docker/docker_harness#86 -- SKIPPED is a legitimate
  # terminal state (job-level if: evaluated false). Treated as
  # success-equivalent so the doc-only short-circuit pattern (base#317)
  # does not hang forever.
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"Integration","status":"COMPLETED","conclusion":"SKIPPED"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "PR1: checks=all-pass mergeable=MERGEABLE"
  assert_output --partial "ALL_DONE"
}

@test "multiple PRs all-pass + MERGEABLE exits 0" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1,2,3 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "PR1:"
  assert_output --partial "PR2:"
  assert_output --partial "PR3:"
  assert_output --partial "ALL_DONE"
}

@test "custom --check-filter narrows to a non-default check name" {
  # Default filter looks for name=="test"; provide only name=="build"
  # → with default filter, length==0 → no-checks → not ready → loops.
  # With --check-filter '.name=="build"' → all-pass → ALL_DONE.
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"build","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 3 \
    --check-filter '.name=="build"'
  assert_success
  assert_output --partial "ALL_DONE"
}

@test "max-iterations exits 124 when stuck pending" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"PENDING"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 2
  assert_equal "${status}" 124
  assert_output --partial "max-iterations"
}

@test "no matching checks counts as no-checks (not all-pass) and loops" {
  # statusCheckRollup has only "lint", default filter wants "test" → length==0 → no-checks.
  # Should NOT trigger ALL_DONE — we exit 124 via max-iterations.
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"lint","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 2
  assert_equal "${status}" 124
  assert_output --partial "checks=no-checks"
}

@test "all-pass but UNKNOWN mergeable does not exit ALL_DONE" {
  stub_gh '{"mergeable":"UNKNOWN","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 2
  assert_equal "${status}" 124
  assert_output --partial "PR1: checks=all-pass mergeable=UNKNOWN"
  refute_output --partial "ALL_DONE"
}

# --min-checks / status guard regressions (false-positive ALL_DONE seen
# multiple times during the template v0.22.0 release and #57 fanout when
# GitHub's PR rollup briefly returned a SUBSET of expected checks before
# every workflow job had registered).

@test "--min-checks 2 with only 1 matching SUCCESS stays pending" {
  # Subset-rollup race: filter matches `test` and `Integration ...` checks
  # but at this poll only Integration has registered. Without --min-checks
  # the original jq pipeline reports all-pass over the single SUCCESS
  # element; --min-checks 2 keeps it pending until the second check shows.
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"Integration E2E","status":"COMPLETED","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 2 \
    --min-checks 2
  assert_equal "${status}" 124
  assert_output --partial "PR1: checks=pending mergeable=MERGEABLE"
  refute_output --partial "checks=all-pass"
  refute_output --partial "ALL_DONE"
}

@test "--min-checks default 1 preserves backwards-compatible behaviour" {
  # Without --min-checks, the original 1-check-SUCCESS case still reports
  # all-pass — ensures the new guard is opt-in.
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ALL_DONE"
}

@test "status IN_PROGRESS blocks all-pass even when conclusion field absent" {
  # A check that registered but has not finished. Real GitHub API returns
  # status="IN_PROGRESS" with conclusion="" (empty string) for in-flight
  # jobs. The status guard catches this earlier than the conclusion check
  # and produces an actionable "pending" label.
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"IN_PROGRESS","conclusion":""}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 2
  assert_equal "${status}" 124
  assert_output --partial "checks=pending"
  refute_output --partial "checks=all-pass"
}

@test "status COMPLETED + conclusion SUCCESS reaches ALL_DONE" {
  # Positive control for the status guard: a fully-finished check passes
  # both `status == COMPLETED` and `conclusion == SUCCESS`.
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ALL_DONE"
}

@test "--min-checks non-integer exits 2" {
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --min-checks foo
  assert_failure 2
  assert_output --partial "--min-checks"
}

@test "--min-checks 0 exits 2 (must be positive)" {
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --min-checks 0
  assert_failure 2
  assert_output --partial "--min-checks"
}

# Stale-rollup guards (refs ycpss91255-docker/docker_harness#60).

@test "all-pass with all completedAt predating watch start → pending" {
  # Force-push scenario: every matching check is from a prior run.
  # 1970 epoch guarantees < watch_start regardless of test wall clock.
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"1970-01-01T00:00:00Z"}],"headRefOid":"a000000aaaaaaaa"}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 2
  assert_equal "${status}" 124
  assert_output --partial "PR1: checks=pending"
  refute_output --partial "checks=all-pass"
  refute_output --partial "ALL_DONE"
}

@test "all-pass with completedAt newer than watch start → ALL_DONE" {
  # Positive control: year 2099 guarantees > watch_start.
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2099-01-01T00:00:00Z"}],"headRefOid":"a000000aaaaaaaa"}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ALL_DONE"
}

@test "headRefOid change between polls emits [head-moved] and forces pending" {
  # Force-push during active watch:
  # iter 1: SHA A, still IN_PROGRESS (pending, watch continues).
  # iter 2: SHA B, statusCheckRollup might show stale all-pass — but
  # head_moved detection forces pending so ALL_DONE is not reached.
  stub_gh_seq \
    '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"IN_PROGRESS","conclusion":""}],"headRefOid":"a000000aaaaaaaa"}' \
    '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2099-01-01T00:00:00Z"}],"headRefOid":"b111111bbbbbbbb"}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 2
  assert_equal "${status}" 124
  assert_output --partial "[head-moved] PR1 a000000..b111111"
  assert_output --partial "PR1: checks=pending"
  refute_output --partial "ALL_DONE"
}

@test "stable headRefOid across polls preserves ALL_DONE path" {
  # Negative control: same SHA on consecutive polls + future completedAt
  # → no head-moved, no staleness demotion → ALL_DONE.
  stub_gh_seq \
    '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2099-01-01T00:00:00Z"}],"headRefOid":"a000000aaaaaaaa"}' \
    '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2099-01-01T00:00:00Z"}],"headRefOid":"a000000aaaaaaaa"}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ALL_DONE"
  refute_output --partial "[head-moved]"
}

@test "JSON without headRefOid preserves backwards-compatible behaviour" {
  # No headRefOid field → current_oid empty → no head-moved detection.
  # Existing test stubs that omit headRefOid keep working.
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ALL_DONE"
  refute_output --partial "[head-moved]"
}

@test "state=MERGED with mergeable=UNKNOWN exits 0 with ALL_DONE (auto-merge race)" {
  # refs ycpss91255-docker/docker_harness#113. After `gh pr merge --auto`
  # completes, GitHub stops recomputing `mergeable`, leaving it stuck at
  # UNKNOWN. .state=MERGED is authoritative: short-circuit to ALL_DONE
  # without waiting for `mergeable=MERGEABLE`.
  stub_gh '{"state":"MERGED","mergeable":"UNKNOWN","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "PR1: state=MERGED (auto-merge completed)"
  assert_output --partial "ALL_DONE"
  refute_output --partial "checks=all-pass"
}

@test "state=CLOSED without merge exits 1 with FAIL <pr>" {
  # PR closed without merge -> terminal failure, not a retryable state.
  stub_gh '{"state":"CLOSED","mergeable":"UNKNOWN","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 5 --interval 0 --max-iterations 3
  assert_failure 1
  assert_output --partial "PR5: state=CLOSED without merge"
  assert_output --partial "FAIL 5 (state=CLOSED without merge)"
}

@test "state-transition mid-poll: OPEN/pending -> MERGED reaches ALL_DONE" {
  # Poll 1: OPEN + still-pending CI. Poll 2: MERGED. Script must terminate
  # cleanly without an orphan `mergeable=UNKNOWN` line lingering.
  stub_gh_seq \
    '{"state":"OPEN","mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","status":"IN_PROGRESS","conclusion":""}]}' \
    '{"state":"MERGED","mergeable":"UNKNOWN","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "checks=pending"
  assert_output --partial "PR1: state=MERGED"
  assert_output --partial "ALL_DONE"
}

@test "absent .state field preserves backwards-compatible behaviour" {
  # Existing stubs that omit .state -> jq returns "?" -> short-circuit
  # case falls through to the original mergeable+rollup logic.
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "PR1: checks=all-pass mergeable=MERGEABLE"
  assert_output --partial "ALL_DONE"
  refute_output --partial "state=MERGED"
}

# ---- event-log emit (refs #175 Phase 1) ----
#
# On every terminal exit the script appends one JSON object to
# `${HOME}/.claude/log/wait-pr-ci-events.log` so Phase 2 can classify
# "Monitor stuck" failure modes from real telemetry. Schema below; each
# test below pins one exit_reason + the surrounding shape.

@test "ALL_DONE appends one JSON event line with full schema" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ALL_DONE"
  local log="${HOME}/.claude/log/wait-pr-ci-events.log"
  [[ -f "${log}" ]] || { echo "log file not created at ${log}"; return 1; }
  local lines
  lines="$(wc -l < "${log}")"
  [[ "${lines}" == "1" ]] || { echo "want 1 log line, got ${lines}"; cat "${log}"; return 1; }
  jq -e '
    .script == "wait-pr-ci.sh"
    and .repo == "a/b"
    and .prs == [1]
    and .exit_reason == "ALL_DONE"
    and (.iterations | type) == "number"
    and (.elapsed_sec | type) == "number"
    and (.head_moves | type) == "number"
    and (.ts | type) == "string"
  ' "${log}" >/dev/null \
    || { echo "schema mismatch:"; cat "${log}"; return 1; }
}

@test "FAIL appends event line with exit_reason=FAIL" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"FAILURE"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 7 --interval 0 --max-iterations 3
  assert_failure 1
  assert_output --partial "FAIL 7"
  local log="${HOME}/.claude/log/wait-pr-ci-events.log"
  [[ -f "${log}" ]] || { echo "log not at ${log}"; return 1; }
  jq -e '.exit_reason == "FAIL" and .prs == [7] and .repo == "a/b"' "${log}" >/dev/null \
    || { cat "${log}"; return 1; }
}

@test "max-iterations appends event line with exit_reason=timeout_max_iter" {
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"PENDING"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 9 --interval 0 --max-iterations 2
  assert_equal "${status}" 124
  local log="${HOME}/.claude/log/wait-pr-ci-events.log"
  [[ -f "${log}" ]] || { echo "log not at ${log}"; return 1; }
  jq -e '.exit_reason == "timeout_max_iter" and .iterations == 2' "${log}" >/dev/null \
    || { cat "${log}"; return 1; }
}

@test "write failure is silent: log path is a dir (EISDIR) -> script still ALL_DONE" {
  # Sabotage the log path: make wait-pr-ci-events.log a directory instead
  # of a regular file. `>> path` then fails with EISDIR even for root in
  # the test container (chmod 000 would not suffice -- root bypasses
  # DAC). Script must still exit normally; emit failure is non-fatal.
  mkdir -p "${HOME}/.claude/log/wait-pr-ci-events.log"
  stub_gh '{"mergeable":"MERGEABLE","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS"}]}'
  run "$(script wait-pr-ci.sh)" --repo a/b --prs 1 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "ALL_DONE"
  refute_output --partial "Permission denied"
  refute_output --partial "Is a directory"
}
