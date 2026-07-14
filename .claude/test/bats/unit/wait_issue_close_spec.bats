#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  GH_STUB_DIR="$(mktemp -d)"
  export PATH="${GH_STUB_DIR}:${PATH}"
}

teardown() {
  rm -rf "${GH_STUB_DIR}"
}

stub_gh() {
  local json="$1"
  printf '#!/usr/bin/env bash\nprintf %%s %q\n' "${json}" > "${GH_STUB_DIR}/gh"
  chmod +x "${GH_STUB_DIR}/gh"
}

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
  run "$(script wait-issue-close.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--repo"
  assert_output --partial "--issue"
}

@test "missing --repo exits 2" {
  run "$(script wait-issue-close.sh)" --issue 1
  assert_failure 2
  assert_output --partial "--repo"
}

@test "missing --issue exits 2" {
  run "$(script wait-issue-close.sh)" --repo a/b
  assert_failure 2
  assert_output --partial "--issue"
}

@test "non-numeric --issue exits 2" {
  run "$(script wait-issue-close.sh)" --repo a/b --issue abc
  assert_failure 2
  assert_output --partial "--issue"
}

@test "unknown flag exits 2" {
  run "$(script wait-issue-close.sh)" --bogus
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
}

@test "state=OPEN keeps polling and hits max-iterations 124" {
  stub_gh '{"state":"OPEN","closedByPullRequestsReferences":[]}'
  run "$(script wait-issue-close.sh)" --repo a/b --issue 7 --interval 0 --max-iterations 3
  assert_failure 124
  assert_output --partial "issue#7: state=OPEN"
  refute_output --partial "issue#7: state=CLOSED"
}

@test "state=CLOSED exits 0 with snapshot" {
  stub_gh '{"state":"CLOSED","closedByPullRequestsReferences":[]}'
  run "$(script wait-issue-close.sh)" --repo a/b --issue 9 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "issue#9: state=CLOSED"
}

@test "CLOSED with linked PRs shows linked= field" {
  stub_gh '{"state":"CLOSED","closedByPullRequestsReferences":[{"number":42},{"number":43}]}'
  run "$(script wait-issue-close.sh)" --repo a/b --issue 9 --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "issue#9: state=CLOSED linked=PR#42,PR#43"
}

@test "--on-close message printed on CLOSED" {
  stub_gh '{"state":"CLOSED","closedByPullRequestsReferences":[]}'
  run "$(script wait-issue-close.sh)" --repo a/b --issue 9 --interval 0 --max-iterations 3 \
    --on-close "now ok to fanout downstream"
  assert_success
  assert_output --partial "now ok to fanout downstream"
}

@test "--on-close not printed while OPEN" {
  stub_gh '{"state":"OPEN","closedByPullRequestsReferences":[]}'
  run "$(script wait-issue-close.sh)" --repo a/b --issue 9 --interval 0 --max-iterations 2 \
    --on-close "should not print"
  assert_failure 124
  refute_output --partial "should not print"
}

@test "stable OPEN across iterations emits one snapshot (dedup)" {
  stub_gh '{"state":"OPEN","closedByPullRequestsReferences":[]}'
  run "$(script wait-issue-close.sh)" --repo a/b --issue 9 --interval 0 --max-iterations 4
  assert_failure 124
  # exactly one "state=OPEN" line.
  local count
  count=$(printf '%s\n' "${output}" | grep -c 'issue#9: state=OPEN')
  [ "${count}" -eq 1 ]
}

@test "transition OPEN -> CLOSED emits both snapshots and exits 0" {
  stub_gh_seq \
    '{"state":"OPEN","closedByPullRequestsReferences":[]}' \
    '{"state":"CLOSED","closedByPullRequestsReferences":[{"number":99}]}'
  run "$(script wait-issue-close.sh)" --repo a/b --issue 9 --interval 0 --max-iterations 4
  assert_success
  assert_output --partial "issue#9: state=OPEN"
  assert_output --partial "issue#9: state=CLOSED linked=PR#99"
}
