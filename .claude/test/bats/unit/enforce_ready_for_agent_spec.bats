#!/usr/bin/env bats
#
# Gate A (#294): applying `ready-for-agent` is refused unless the issue
# carries the four parts ADR-00000015 says the label asserts -- Seams,
# First slice, Gate, Bound.

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

# md <line>... -- join lines into one markdown blob.
md() {
  printf '%s\n' "$@"
}

# seed_labels <name>... -- the repo's label inventory.
seed_labels() {
  printf '%s\n' "$@" | jq -R . | jq -s 'map({name: .})' > "${GH_STUB_LABELS}"
}

# seed_issue <body> [comment-body...] -- the issue the gate will read.
# Body and comments are SEPARATE fields, exactly as the GitHub API
# returns them, so a check that reads only the body cannot pass a test
# whose parts live in a comment.
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

# all_four -- a body carrying every part, the honest-label case.
all_four() {
  md '## Seams' 'lib/x.sh -- one function, one caller' \
     '## First slice' 'the first failing test' \
     '## Gate' 'just -f .claude/test/justfile check' \
     '## Bound' '6 red-green cycles'
}

# install_gh_stub -- a `gh` on PATH that answers the two queries the gate
# makes the way gh answers them: it honours `--json <fields>` by
# projecting the fixture down to those fields FIRST, then applies the
# caller's `--jq` to the result. A gate that forgets to ask for
# `comments` therefore sees no comments here either.
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

# uninstall_gh -- a PATH with no gh at all (the "cannot be asked" case).
uninstall_gh() {
  rm -f "${TMP}/bin/gh"
}

# Slice 1 -- an unready issue cannot take the label, and the denial says
# which part is missing.

@test "add-label ready-for-agent on an issue missing a part is denied, naming it" {
  seed_issue "$(md '## Seams' 'x' '## First slice' 'y' '## Gate' 'z')"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit 42 --add-label ready-for-agent"}}'
  assert_permission_decision "deny"
  assert_message_contains "Bound"
}

@test "the denial names every missing part, not just the first" {
  seed_issue "$(md '## Seams' 'x' '## Gate' 'z')"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit 42 --add-label ready-for-agent"}}'
  assert_permission_decision "deny"
  assert_message_contains "First slice"
  assert_message_contains "Bound"
}

# Slice 2 -- the gate fires on ready-for-agent, wherever in the
# --add-label flags it sits, and on nothing else.

@test "add-label ready-for-agent on a complete issue is silent" {
  seed_issue "$(all_four)"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit 42 --add-label ready-for-agent"}}'
  assert_silent
}

@test "ready-for-agent behind a second --add-label flag is still gated" {
  seed_issue "$(md '## Seams' 'x' '## First slice' 'y' '## Gate' 'z')"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit 42 --add-label bug --add-label ready-for-agent"}}'
  assert_permission_decision "deny"
  assert_message_contains "Bound"
}

@test "ready-for-agent inside a comma-separated --add-label is still gated" {
  seed_issue "$(md '## Seams' 'x' '## First slice' 'y' '## Gate' 'z')"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit 42 --add-label \"bug,ready-for-agent\""}}'
  assert_permission_decision "deny"
}

@test "adding a different label to the same unready issue is untouched" {
  seed_issue "$(md '## Seams' 'x')"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit 42 --add-label enhancement"}}'
  assert_silent
}

@test "removing ready-for-agent from an unready issue is untouched" {
  seed_issue "$(md '## Seams' 'x')"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit 42 --remove-label ready-for-agent"}}'
  assert_silent
}

@test "a label that merely contains ready-for-agent is not the label" {
  seed_issue "$(md '## Seams' 'x')"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit 42 --add-label not-ready-for-agent-yet"}}'
  assert_silent
}

# Slice 3 -- the parts count wherever they were written. The issue body
# is the original spec and does not get rewritten, so a grill's
# conclusions arrive as a COMMENT; a body-only check would fail every
# grilled issue against its own gate.

@test "the four parts are found when they live in a comment, not the body" {
  seed_issue "$(md '## Context' 'the original spec, unrewritten')" \
             "$(all_four)"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit 42 --add-label ready-for-agent"}}'
  assert_silent
}

@test "parts split across the body and a comment together count" {
  seed_issue "$(md '## Seams' 'x' '## First slice' 'y')" \
             "$(md '## Gate' 'z' '## Bound' '6 cycles')"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit 42 --add-label ready-for-agent"}}'
  assert_silent
}

@test "comments that do not supply the missing part still leave it missing" {
  seed_issue "$(md '## Seams' 'x' '## First slice' 'y' '## Gate' 'z')" \
             "$(md 'looks good to me')" \
             "$(md '## Notes' 'no bound here')"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit 42 --add-label ready-for-agent"}}'
  assert_permission_decision "deny"
  assert_message_contains "Bound"
}

# Slice 4 -- the gate answers for the issue however the command names
# it. gh takes a number or a full issue URL, and a URL also carries its
# own repo, overriding any -R on the line.

@test "the gate reads the repo and number out of an issue URL" {
  seed_issue "$(md '## Seams' 'x' '## First slice' 'y' '## Gate' 'z')"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit https://github.com/ycpss91255-docker/base/issues/42 --add-label ready-for-agent"}}'
  assert_permission_decision "deny"
  assert_message_contains "#42"
  assert_message_contains "Bound"
}

@test "a complete issue named by URL still takes the label" {
  seed_issue "$(all_four)"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit https://github.com/ycpss91255-docker/base/issues/42 --add-label ready-for-agent"}}'
  assert_silent
}

@test "an explicit -R repo is used for the lookup" {
  seed_issue "$(md '## Seams' 'x')"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit 42 -R ycpss91255-docker/base --add-label ready-for-agent"}}'
  assert_permission_decision "deny"
}

@test "an issue argument that is neither a number nor a URL is silent" {
  seed_issue "$(md '## Seams' 'x')"
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit \"${issue_ref}\" --add-label ready-for-agent"}}'
  assert_silent
}

