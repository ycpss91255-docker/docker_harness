#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  TMP="$(mktemp -d)"
  GH_STUB_DIR="${TMP}/bin"
  mkdir -p "${GH_STUB_DIR}"
}

teardown() {
  rm -rf "${TMP}"
}

# stub_gh_view_comments <body...> — install a `gh` shim whose
# `gh issue view ... --json comments` prints the given comment
# bodies (one per arg, newline-joined). Any other gh subcommand
# exits 0 with no output. Used for Check B (refs #196).
stub_gh_view_comments() {
  local out=""
  local b
  for b in "$@"; do
    out+="${b}"$'\n'
  done
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [[ "$*" == *"issue view"* ]]; then\n'
    printf '  cat <<'\''BODYEOF'\''\n%sBODYEOF\n' "${out}"
    printf 'fi\n'
    printf 'exit 0\n'
  } > "${GH_STUB_DIR}/gh"
  chmod +x "${GH_STUB_DIR}/gh"
}

# stub_gh_fail — install a `gh` shim that exits non-zero (network
# failure simulation for the Check B fail-open path).
stub_gh_fail() {
  printf '#!/usr/bin/env bash\nexit 1\n' > "${GH_STUB_DIR}/gh"
  chmod +x "${GH_STUB_DIR}/gh"
}

# Rule 8 -- parser-fallback patterns deny everywhere.

@test "rule 8: gh issue close --comment \"\$(cat path)\" denied" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue close 1 --comment \"$(cat /tmp/x.md)\""}}'
  assert_permission_decision "deny"
}

@test "rule 8: gh pr create --body \"\$(cat path)\" denied" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh pr create --body \"$(cat /tmp/body.md)\" --title T"}}'
  assert_permission_decision "deny"
}

@test "rule 8: gh pr edit --body \$(cat path) without quotes denied" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh pr edit 5 --body $(cat /tmp/x.md)"}}'
  assert_permission_decision "deny"
}

@test "rule 8: gh pr create --body-file - <<EOF heredoc denied" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh pr create --title T --body-file - <<EOF\nbody line\nEOF"}}'
  assert_permission_decision "deny"
}

@test "rule 8: gh issue create --body-file - alone (stdin variant) denied" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue create --title T --body-file -"}}'
  assert_permission_decision "deny"
}

# Rules 1 & 4 -- gh issue|pr create require --body-file <path>.

@test "rule 1: gh issue create without --body-file denied" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue create --title T --body \"short body\""}}'
  assert_permission_decision "deny"
}

@test "rule 1: gh issue create with --body-file + --label allowed (silent)" {
  # Post #91: issue create needs both --body-file (rule 1) and --label
  # (rule 9). With label present the call is fully silent.
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue create --title T --body-file /tmp/x.md --label enhancement"}}'
  assert_silent
}

@test "rule 9: gh issue create with --body-file but no --label denied" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue create --title T --body-file /tmp/x.md"}}'
  assert_permission_decision "deny"
  assert_message_contains "Rule 9 of #91"
  assert_message_contains "--label"
}

@test "rule 9: gh issue create with --label= form allowed" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue create --title T --body-file /tmp/x.md --label=enhancement"}}'
  assert_silent
}

@test "rule 9: gh issue create with -l short form allowed" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue create --title T --body-file /tmp/x.md -l bug"}}'
  assert_silent
}

@test "rule 9: gh issue create with quoted multi-word label allowed" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue create --title T --body-file /tmp/x.md --label \"help wanted\""}}'
  assert_silent
}

@test "rule 9: gh issue create with two --label flags allowed" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue create --title T --body-file /tmp/x.md --label bug --label \"help wanted\""}}'
  assert_silent
}

@test "rule 9: gh issue create with empty --label \"\" denied" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue create --title T --body-file /tmp/x.md --label \"\""}}'
  assert_permission_decision "deny"
  assert_message_contains "Rule 9 of #91"
}

@test "rule 9: gh issue create with --label= (empty after equals) denied" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue create --title T --body-file /tmp/x.md --label="}}'
  assert_permission_decision "deny"
  assert_message_contains "Rule 9 of #91"
}

@test "rule 9: gh pr create without --label still allowed (PR exempt)" {
  # PRs inherit labels from the issue they close; rule 9 only applies
  # to issue create.
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh pr create --title T --body-file /tmp/x.md"}}'
  assert_silent
}

@test "rule 4: gh pr create without --body-file denied (short inline body)" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh pr create --title T --body \"LGTM\""}}'
  assert_permission_decision "deny"
}

@test "rule 4: gh pr create with --body-file /tmp/x.md allowed" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh pr create --title T --body-file /tmp/x.md"}}'
  assert_silent
}

@test "rule 4: gh pr create --body-file path with dash-like name allowed" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh pr create --body-file /tmp/-weird-name.md --title T"}}'
  assert_silent
}

# Rule 3 -- gh issue close --comment denied (two-step required).

@test "rule 3: gh issue close N --comment \"...\" denied" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue close 42 --comment \"done\""}}'
  assert_permission_decision "deny"
}

@test "rule 3: gh issue close N -c \"...\" (short form) denied" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue close 42 -c \"done\""}}'
  assert_permission_decision "deny"
}

@test "rule 3: gh issue close N --reason completed (no comment) allowed" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue close 42 --reason completed"}}'
  assert_silent
}

@test "rule 3: gh issue close N --reason \"not planned\" allowed" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue close 42 --reason \"not planned\""}}'
  assert_silent
}

@test "rule 3: gh issue close N (no args beyond N) allowed" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue close 42"}}'
  assert_silent
}

# Rule 6 -- gh pr edit --body inline denied.

@test "rule 6: gh pr edit N --body \"inline\" denied" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh pr edit 7 --body \"new body\""}}'
  assert_permission_decision "deny"
}

@test "rule 6: gh pr edit N --body-file /tmp/x.md allowed" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh pr edit 7 --body-file /tmp/x.md"}}'
  assert_silent
}

@test "rule 6: gh pr edit N --add-label \"x\" (no body) allowed" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh pr edit 7 --add-label \"x\""}}'
  assert_silent
}

# Rules 2 / 5 / 7 -- inline body threshold (80 chars, single line).

@test "rule 2: gh issue comment N --body \"<=80 single-line\" allowed" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh issue comment 1 --body \"merged via #45\""}}'
  assert_silent
}

@test "rule 2: gh issue comment N --body \"<long string>\" denied" {
  local long_body="this body is intentionally longer than eighty characters to trip the threshold rule"
  run "$(hook enforce_gh_body_file.sh)" <<< "{\"tool_input\":{\"command\":\"gh issue comment 1 --body \\\"${long_body}\\\"\"}}"
  assert_permission_decision "deny"
}

@test "rule 5: gh pr comment N --body \"<=80\" allowed" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh pr comment 9 --body \"CI green, merging\""}}'
  assert_silent
}

@test "rule 5: gh pr comment N --body \"<long>\" denied" {
  local long_body="multi paragraph review comment that has more characters than the eighty char limit"
  run "$(hook enforce_gh_body_file.sh)" <<< "{\"tool_input\":{\"command\":\"gh pr comment 9 --body \\\"${long_body}\\\"\"}}"
  assert_permission_decision "deny"
}

@test "rule 7: gh pr review --body \"LGTM\" allowed" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh pr review 9 --approve --body \"LGTM\""}}'
  assert_silent
}

@test "rule 7: gh pr review --body \"<long>\" denied" {
  local long_body="a review comment longer than eighty chars triggers the threshold and gets denied accordingly"
  run "$(hook enforce_gh_body_file.sh)" <<< "{\"tool_input\":{\"command\":\"gh pr review 9 --request-changes --body \\\"${long_body}\\\"\"}}"
  assert_permission_decision "deny"
}

# Silent on non-gh and non-listed subcommands.

@test "silent on non-gh command using \$(cat path)" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"echo \"$(cat /tmp/x.md)\""}}'
  assert_silent
}

@test "silent on gh pr view (no body involvement)" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh pr view 5 --json state"}}'
  assert_silent
}

@test "silent on gh pr merge --auto (no body)" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh pr merge 5 --auto --squash"}}'
  assert_silent
}

@test "silent on gh run view <id> --json jobs" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh run view 123 --json jobs"}}'
  assert_silent
}

@test "silent on gh api /repos/.../issues/N" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"command":"gh api /repos/owner/repo/issues/1"}}'
  assert_silent
}

@test "silent on empty tool_input" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{}'
  assert_silent
}

@test "silent on non-Bash tool_input shape (e.g. Edit)" {
  run "$(hook enforce_gh_body_file.sh)" <<< '{"tool_input":{"file_path":"/tmp/x.md"}}'
  assert_silent
}

# Threshold boundary: exactly 80 chars allowed; 81 denied.

@test "rule 2: gh issue comment --body \"<exactly 80 chars>\" allowed" {
  local body80="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  # body80 = 80 'a' chars (boundary lower)
  run "$(hook enforce_gh_body_file.sh)" <<< "{\"tool_input\":{\"command\":\"gh issue comment 1 --body \\\"${body80}\\\"\"}}"
  assert_silent
}

@test "rule 2: gh issue comment --body \"<81 chars>\" denied" {
  local body81="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  # body81 = 81 'a' chars (boundary upper, just over)
  run "$(hook enforce_gh_body_file.sh)" <<< "{\"tool_input\":{\"command\":\"gh issue comment 1 --body \\\"${body81}\\\"\"}}"
  assert_permission_decision "deny"
}

# Decision-record enforcement (refs #196).
# Check A: a PR whose body-file closes #N must carry a ## Resolution
# or ## Decision section. Check B: a manual `gh issue close N` needs
# an existing comment carrying that marker.

@test "#196 A: pr create closing #N without decision record denied" {
  local bf="${TMP}/body.md"
  printf '## Summary\n\nDid a thing.\n\nCloses #5\n' > "${bf}"
  run "$(hook enforce_gh_body_file.sh)" <<< "{\"tool_input\":{\"command\":\"gh pr create --title T --body-file ${bf}\"}}"
  assert_permission_decision "deny"
}

@test "#196 A: pr create closing #N WITH ## Resolution allowed" {
  local bf="${TMP}/body.md"
  printf '## Summary\n\nDid a thing.\n\n## Resolution\n\nChose X.\n\nCloses #5\n' > "${bf}"
  run "$(hook enforce_gh_body_file.sh)" <<< "{\"tool_input\":{\"command\":\"gh pr create --title T --body-file ${bf}\"}}"
  assert_silent
}

@test "#196 A: pr create closing #N WITH ## Decision allowed" {
  local bf="${TMP}/body.md"
  printf '## Decision\n\nWent with Y because Z.\n\nFixes #9\n' > "${bf}"
  run "$(hook enforce_gh_body_file.sh)" <<< "{\"tool_input\":{\"command\":\"gh pr create --title T --body-file ${bf}\"}}"
  assert_silent
}

@test "#196 A: pr create NOT closing any issue needs no decision record" {
  local bf="${TMP}/body.md"
  printf '## Summary\n\nRefactor only, refs #5.\n' > "${bf}"
  run "$(hook enforce_gh_body_file.sh)" <<< "{\"tool_input\":{\"command\":\"gh pr create --title T --body-file ${bf}\"}}"
  assert_silent
}

@test "#196 A: pr create with unreadable body-file fails open (silent)" {
  run "$(hook enforce_gh_body_file.sh)" <<< "{\"tool_input\":{\"command\":\"gh pr create --title T --body-file ${TMP}/does-not-exist.md\"}}"
  assert_silent
}
