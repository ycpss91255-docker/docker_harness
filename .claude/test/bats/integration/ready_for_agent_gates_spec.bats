#!/usr/bin/env bats
#
# Integration: the two gates of ADR-00000015 answer two different
# questions off ONE implementation. Gate A (the PreToolUse hook) asks
# whether the label being applied is honest; Gate B (the callable check
# #296 runs before opening a worktree) asks whether the work is safe to
# start. They must never disagree about whether the four parts are
# present -- that divergence is what two copies of the check would
# produce, and it is the failure this repo keeps repairing.

load '../lib/test_helper'

setup() {
  TMP="$(mktemp -d)"
  export GH_STUB_LABELS="${TMP}/labels.json"
  export GH_STUB_ISSUE="${TMP}/issue.json"
  mkdir -p "${TMP}/bin"
  printf '%s\n' 'bug' 'ready-for-agent' | jq -R . | jq -s 'map({name: .})' \
    > "${GH_STUB_LABELS}"
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

teardown() {
  rm -rf "${TMP}"
}

# seed <body> [comment...] -- the issue both gates will read.
seed() {
  local body="$1"
  shift
  local comments='[]'
  if (( $# > 0 )); then
    comments="$(printf '%s\n' "$@" | jq -R . | jq -s 'map({body: .})')"
  fi
  jq -n --arg b "${body}" --argjson c "${comments}" \
    '{body: $b, comments: $c}' > "${GH_STUB_ISSUE}"
}

gate_a() {
  "$(hook enforce_ready_for_agent.sh)" \
    <<< '{"tool_input":{"command":"gh issue edit 42 --add-label ready-for-agent"}}'
}

@test "both gates refuse the same under-specified issue" {
  seed "$(printf '%s\n' '## Seams' 'x' '## First slice' 'y' '## Gate' 'z')"

  run gate_a
  assert_permission_decision "deny"
  assert_message_contains "Bound"

  run "$(script check-ready-for-agent.sh)" 42
  assert_failure 1
  assert_output --partial "Bound"
}

@test "both gates accept the same complete issue" {
  seed "$(printf '%s\n' '## Seams' 'x' '## First slice' 'y' \
                        '## Gate' 'z' '## Bound' '6 cycles')"

  run gate_a
  assert_silent

  run "$(script check-ready-for-agent.sh)" 42
  assert_success
}

@test "both gates accept parts that arrived as a grill comment" {
  seed "$(printf '%s\n' '## Context' 'the original spec, unrewritten')" \
       "$(printf '%s\n' '## Seams' 'x' '## First slice' 'y' \
                        '## Gate' 'z' '## Bound' '6 cycles')"

  run gate_a
  assert_silent

  run "$(script check-ready-for-agent.sh)" 42
  assert_success
}

@test "only Gate A depends on the label being defined in the repo" {
  printf '%s\n' 'bug' 'enhancement' | jq -R . | jq -s 'map({name: .})' \
    > "${GH_STUB_LABELS}"
  seed "$(printf '%s\n' '## Seams' 'x')"

  # Gate A asks about a label this repo does not have -- pure friction,
  # so it says nothing (#278's reasoning).
  run gate_a
  assert_silent

  # Gate B asks whether the work is safe to start, which the label
  # inventory has no bearing on. It still refuses.
  run "$(script check-ready-for-agent.sh)" 42
  assert_failure 1
}
