#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  GH_STUB_DIR="$(mktemp -d)"
  export PATH="${GH_STUB_DIR}:${PATH}"
}

teardown() {
  rm -rf "${GH_STUB_DIR}"
}

# stub_gh_runs <baseline_id> <baseline_json> <fixed_id> <fixed_json>
# Installs a gh shim that echoes baseline_json when $2 == baseline_id and
# fixed_json when $2 == fixed_id. Anything else exits 1 with an error.
stub_gh_runs() {
  local b_id="$1" b_json="$2" f_id="$3" f_json="$4"
  cat > "${GH_STUB_DIR}/gh" <<EOF
#!/usr/bin/env bash
# Args: run view <RUN-ID> --repo <REPO> --json jobs
if [[ "\$1" == "run" && "\$2" == "view" ]]; then
  case "\$3" in
    ${b_id}) printf '%s' '${b_json}'; exit 0 ;;
    ${f_id}) printf '%s' '${f_json}'; exit 0 ;;
    *) echo "unknown run id: \$3" >&2; exit 1 ;;
  esac
fi
echo "unexpected gh invocation: \$*" >&2
exit 1
EOF
  chmod +x "${GH_STUB_DIR}/gh"
}

# stub_gh_fail <baseline_id> <fail_id> -- baseline ok, fixed id triggers
# gh exit 1 with an error message on stderr.
stub_gh_fail() {
  local b_id="$1" b_json="$2" f_id="$3"
  cat > "${GH_STUB_DIR}/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "run" && "\$2" == "view" ]]; then
  case "\$3" in
    ${b_id}) printf '%s' '${b_json}'; exit 0 ;;
    ${f_id}) echo "could not fetch run ${f_id}: not found" >&2; exit 1 ;;
  esac
fi
exit 1
EOF
  chmod +x "${GH_STUB_DIR}/gh"
}

@test "--help prints usage and exits 0" {
  run "$(script ci-wall-time-compare.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--repo"
  assert_output --partial "--baseline"
  assert_output --partial "--fixed"
}

@test "missing --repo exits 2" {
  run "$(script ci-wall-time-compare.sh)" --baseline 1 --fixed 2
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"arg":"--repo"'
}

@test "missing --baseline exits 2" {
  run "$(script ci-wall-time-compare.sh)" --repo a/b --fixed 2
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"arg":"--baseline"'
}

@test "missing --fixed exits 2" {
  run "$(script ci-wall-time-compare.sh)" --repo a/b --baseline 1
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"arg":"--fixed"'
}

@test "unknown arg exits 2" {
  run "$(script ci-wall-time-compare.sh)" --bogus
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
  assert_output --partial '"arg":"--bogus"'
}

@test "all jobs match, fixed faster -> table with negative deltas" {
  local b f
  b='{"jobs":[{"name":"humble/amd64","startedAt":"2026-05-01T00:00:00Z","completedAt":"2026-05-01T00:16:56Z"},{"name":"humble/arm64","startedAt":"2026-05-01T00:00:00Z","completedAt":"2026-05-01T00:18:25Z"}]}'
  f='{"jobs":[{"name":"humble/amd64","startedAt":"2026-05-02T00:00:00Z","completedAt":"2026-05-02T00:13:10Z"},{"name":"humble/arm64","startedAt":"2026-05-02T00:00:00Z","completedAt":"2026-05-02T00:11:28Z"}]}'
  stub_gh_runs 1001 "${b}" 2002 "${f}"
  run "$(script ci-wall-time-compare.sh)" --repo a/b --baseline 1001 --fixed 2002
  assert_success
  assert_output --partial "| humble/amd64 | 16m56s | 13m10s |"
  assert_output --partial "| humble/arm64 | 18m25s | 11m28s |"
  assert_output --partial "-3m46s"
  assert_output --partial "-6m57s"
  assert_output --partial "| **total wall** |"
}

@test "fixed slower -> positive delta with + prefix" {
  local b f
  b='{"jobs":[{"name":"build","startedAt":"2026-05-01T00:00:00Z","completedAt":"2026-05-01T00:05:00Z"}]}'
  f='{"jobs":[{"name":"build","startedAt":"2026-05-02T00:00:00Z","completedAt":"2026-05-02T00:07:00Z"}]}'
  stub_gh_runs 1 "${b}" 2 "${f}"
  run "$(script ci-wall-time-compare.sh)" --repo a/b --baseline 1 --fixed 2
  assert_success
  assert_output --partial "+2m00s"
  assert_output --partial "+40%"
}

@test "job present in only baseline is skipped (no fixed counterpart)" {
  local b f
  b='{"jobs":[{"name":"keep","startedAt":"2026-05-01T00:00:00Z","completedAt":"2026-05-01T00:01:00Z"},{"name":"drop","startedAt":"2026-05-01T00:00:00Z","completedAt":"2026-05-01T00:02:00Z"}]}'
  f='{"jobs":[{"name":"keep","startedAt":"2026-05-02T00:00:00Z","completedAt":"2026-05-02T00:01:30Z"}]}'
  stub_gh_runs 1 "${b}" 2 "${f}"
  run "$(script ci-wall-time-compare.sh)" --repo a/b --baseline 1 --fixed 2
  assert_success
  assert_output --partial "| keep |"
  refute_output --partial "| drop |"
}

@test "in-progress run (missing completedAt) exits 2" {
  local b f
  b='{"jobs":[{"name":"build","startedAt":"2026-05-01T00:00:00Z","completedAt":null}]}'
  f='{"jobs":[{"name":"build","startedAt":"2026-05-02T00:00:00Z","completedAt":"2026-05-02T00:05:00Z"}]}'
  stub_gh_runs 1 "${b}" 2 "${f}"
  run "$(script ci-wall-time-compare.sh)" --repo a/b --baseline 1 --fixed 2
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"reason":"in-progress-jobs"'
  assert_output --partial "build"
}

@test "in-progress fixed run (missing startedAt) exits 2" {
  local b f
  b='{"jobs":[{"name":"build","startedAt":"2026-05-01T00:00:00Z","completedAt":"2026-05-01T00:01:00Z"}]}'
  f='{"jobs":[{"name":"build","startedAt":null,"completedAt":null}]}'
  stub_gh_runs 1 "${b}" 2 "${f}"
  run "$(script ci-wall-time-compare.sh)" --repo a/b --baseline 1 --fixed 2
  assert_failure 2
  assert_output --partial '"body":"precondition_missing"'
  assert_output --partial '"reason":"in-progress-jobs"'
}

@test "gh API failure exits 1" {
  local b
  b='{"jobs":[{"name":"build","startedAt":"2026-05-01T00:00:00Z","completedAt":"2026-05-01T00:01:00Z"}]}'
  stub_gh_fail 1 "${b}" 999
  run "$(script ci-wall-time-compare.sh)" --repo a/b --baseline 1 --fixed 999
  assert_failure 1
  assert_output --partial '"body":"api_error"'
  assert_output --partial '"tool":"gh-run-view"'
  assert_output --partial '"run_id":"999"'
}

@test "--output writes table to file, stdout is empty" {
  local b f tmp_out
  b='{"jobs":[{"name":"build","startedAt":"2026-05-01T00:00:00Z","completedAt":"2026-05-01T00:01:00Z"}]}'
  f='{"jobs":[{"name":"build","startedAt":"2026-05-02T00:00:00Z","completedAt":"2026-05-02T00:00:30Z"}]}'
  stub_gh_runs 1 "${b}" 2 "${f}"
  tmp_out="$(mktemp)"
  run "$(script ci-wall-time-compare.sh)" --repo a/b --baseline 1 --fixed 2 --output "${tmp_out}"
  assert_success
  assert_output --partial '"body":"lint_pass"'
  assert_output --partial '"kind":"table-written"'
  refute_output --partial "| build |"
  run cat "${tmp_out}"
  assert_output --partial "| build |"
  rm -f "${tmp_out}"
}

@test "table header always present even when no jobs match" {
  local b f
  b='{"jobs":[{"name":"x","startedAt":"2026-05-01T00:00:00Z","completedAt":"2026-05-01T00:01:00Z"}]}'
  f='{"jobs":[{"name":"y","startedAt":"2026-05-02T00:00:00Z","completedAt":"2026-05-02T00:01:00Z"}]}'
  stub_gh_runs 1 "${b}" 2 "${f}"
  run "$(script ci-wall-time-compare.sh)" --repo a/b --baseline 1 --fixed 2
  assert_success
  assert_output --partial "| shard | baseline | fixed | delta |"
  refute_output --partial "**total wall**"
}

@test "equal durations -> +0s (0%) delta" {
  local b f
  b='{"jobs":[{"name":"build","startedAt":"2026-05-01T00:00:00Z","completedAt":"2026-05-01T00:01:00Z"}]}'
  f='{"jobs":[{"name":"build","startedAt":"2026-05-02T00:00:00Z","completedAt":"2026-05-02T00:01:00Z"}]}'
  stub_gh_runs 1 "${b}" 2 "${f}"
  run "$(script ci-wall-time-compare.sh)" --repo a/b --baseline 1 --fixed 2
  assert_success
  assert_output --partial "1m00s | 1m00s | +0s (0%)"
}
