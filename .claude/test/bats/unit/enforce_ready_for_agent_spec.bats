#!/usr/bin/env bats
#
# Gate A (#294): applying `ready-for-agent` is refused unless the issue
# carries the four parts ADR-00000015 says the label asserts -- Seams,
# First slice, Gate, Bound.

load '../lib/test_helper'

setup() {
  TMP="$(mktemp -d)"
  STUB_DIR="${TMP}/bin"
  ISSUE_FILE="${TMP}/issue.txt"
  LABEL_FILE="${TMP}/labels.txt"
  mkdir -p "${STUB_DIR}"
  printf 'bug\nenhancement\nready-for-agent\n' > "${LABEL_FILE}"
  : > "${ISSUE_FILE}"
}

teardown() {
  rm -rf "${TMP}"
}

# seed_issue <line>... -- the text `gh issue view --json body,comments`
# returns for the issue under test.
seed_issue() {
  printf '%s\n' "$@" > "${ISSUE_FILE}"
}

# install_gh_stub -- a `gh` on PATH answering the two queries the gate
# makes: the repo's label inventory and the issue's body + comments.
install_gh_stub() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in\n'
    printf '  *"label list"*) cat %q ;;\n' "${LABEL_FILE}"
    printf '  *"issue view"*) cat %q ;;\n' "${ISSUE_FILE}"
    printf 'esac\n'
    printf 'exit 0\n'
  } > "${STUB_DIR}/gh"
  chmod +x "${STUB_DIR}/gh"
  export PATH="${STUB_DIR}:${PATH}"
}

@test "add-label ready-for-agent on an issue missing a part is denied, naming it" {
  seed_issue \
    '## Seams' 'lib/x.sh -- one function' \
    '## First slice' 'the first failing test' \
    '## Gate' 'just -f .claude/test/justfile check'
  install_gh_stub
  run "$(hook enforce_ready_for_agent.sh)" <<< '{"tool_input":{"command":"gh issue edit 42 --add-label ready-for-agent"}}'
  assert_permission_decision "deny"
  assert_message_contains "Bound"
}
