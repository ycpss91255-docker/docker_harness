#!/usr/bin/env bats
#
# Gate B (#294): the same readiness check, callable. ADR-00000015 records
# the two gates as different questions -- "is this label honest" (the
# hook) and "is this safe to start" (this script, which the fix pipeline
# in #296 runs before it opens a worktree, REGARDLESS of the label).

load '../lib/test_helper'

setup() {
  TMP="$(mktemp -d)"
  export GH_STUB_LABELS="${TMP}/labels.json"
  export GH_STUB_ISSUE="${TMP}/issue.json"
  mkdir -p "${TMP}/bin"
  seed_labels 'bug' 'enhancement' 'ready-for-agent'
  seed_issue ''
  install_gh_stub
}

teardown() {
  rm -rf "${TMP}"
}

md() {
  printf '%s\n' "$@"
}

seed_labels() {
  printf '%s\n' "$@" | jq -R . | jq -s 'map({name: .})' > "${GH_STUB_LABELS}"
}

# seed_issue <body> [comment-body...] -- body and comments kept apart,
# the way the GitHub API returns them.
seed_issue() {
  local body="$1"
  shift
  local comments='[]'
  if (( $# > 0 )); then
    comments="$(printf '%s\n' "$@" | jq -R . | jq -s 'map({body: .})')"
  fi
  jq -n --arg b "${body}" --argjson c "${comments}" \
    '{body: $b, comments: $c}' > "${GH_STUB_ISSUE}"
}

all_four() {
  md '## Seams' 'lib/x.sh -- one function, one caller' \
     '## First slice' 'the first failing test' \
     '## Gate' 'just -f .claude/test/justfile check' \
     '## Bound' '6 red-green cycles'
}

install_gh_stub() {
  cat > "${TMP}/bin/gh" <<'STUBEOF'
#!/usr/bin/env bash
set -uo pipefail
noun=""
fields=""
expr="."
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  case "${args[i]}" in
    label|issue) [[ -z "${noun}" ]] && noun="${args[i]}" ;;
    --json) fields="${args[i+1]}"; i=$(( i + 1 )) ;;
    --jq)   expr="${args[i+1]}";   i=$(( i + 1 )) ;;
  esac
  i=$(( i + 1 ))
done
project="with_entries(select(.key as \$k | \$f | index(\$k)))"
case "${noun}" in
  label)
    jq -r "${expr}" "${GH_STUB_LABELS}"
    ;;
  issue)
    jq -r --argjson f "$(printf '%s' "${fields}" | jq -R 'split(",")')" \
      "${project} | ${expr}" "${GH_STUB_ISSUE}"
    ;;
  *) exit 1 ;;
esac
STUBEOF
  chmod +x "${TMP}/bin/gh"
  export PATH="${TMP}/bin:${PATH}"
}

@test "an issue missing a part exits 1 and names the missing part" {
  seed_issue "$(md '## Seams' 'x' '## First slice' 'y' '## Gate' 'z')"
  run "$(script check-ready-for-agent.sh)" 42
  assert_failure 1
  assert_output --partial "Bound"
}

@test "a complete issue exits 0" {
  seed_issue "$(all_four)"
  run "$(script check-ready-for-agent.sh)" 42
  assert_success
}

@test "the verdict does not depend on the label being defined" {
  seed_labels 'bug' 'enhancement'
  seed_issue "$(all_four)"
  run "$(script check-ready-for-agent.sh)" 42
  assert_success
}

@test "an unready issue that already carries the label still exits 1" {
  seed_labels 'bug' 'ready-for-agent'
  seed_issue "$(md '## Seams' 'x')"
  run "$(script check-ready-for-agent.sh)" 42
  assert_failure 1
  assert_output --partial "First slice"
}

@test "parts living in a comment are found" {
  seed_issue "$(md '## Context' 'the original spec')" "$(all_four)"
  run "$(script check-ready-for-agent.sh)" 42
  assert_success
}

@test "an issue URL is accepted as the target" {
  seed_issue "$(all_four)"
  run "$(script check-ready-for-agent.sh)" \
    "https://github.com/ycpss91255-docker/base/issues/42"
  assert_success
}

@test "a gh that cannot answer exits 2, never a false ready" {
  rm -f "${TMP}/bin/gh"
  run "$(script check-ready-for-agent.sh)" 42
  assert_failure 2
}

@test "no issue argument exits 2 with usage" {
  run "$(script check-ready-for-agent.sh)"
  assert_failure 2
}

@test "--help exits 0 with usage" {
  run "$(script check-ready-for-agent.sh)" --help
  assert_success
  assert_output --partial "Usage:"
}
