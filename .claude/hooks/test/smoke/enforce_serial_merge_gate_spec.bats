#!/usr/bin/env bats
# enforce_serial_merge_gate.sh -- PreToolUse Bash hook that DENIES the 2nd+
# same-repo `gh pr merge ... --auto` arm of a batch, routing the operator to
# serial-merge.sh (issue #236). Detection: on an `--auto` arm, query the
# target repo's open PRs for ones already armed for auto-merge
# (`gh pr list --repo <repo> --state open --json number,autoMergeRequest`).
# 0 already armed -> ALLOW (single arm, silent). >= 1 already armed -> DENY
# with a data-rich message (repo + armed list + ready-to-paste
# serial-merge.sh command). Lift via the /tmp checkpoint protocol
# (ADR-00000002) or the SERIAL_MERGE=1 explicit bypass.
#
# Strategy: PATH-stub `gh` so `gh pr list ... --json` returns a synthetic
# open-PR array driven by the ARMED env var (space-separated PR numbers
# that report a non-null autoMergeRequest). Non-list gh calls are no-ops.

load '../lib/test_helper'

setup() {
  export TMPDIR="${BATS_TEST_TMPDIR}"
  export CLAUDE_SESSION_ID="enforce-serial-merge-gate-spec"

  STUB_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${STUB_DIR}"

  # Fake gh: only `gh pr list ... --json ...` matters. Emit one object per
  # ARMED PR number with a non-null autoMergeRequest; everything else null.
  cat > "${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  printf '['
  first=1
  for n in ${ARMED:-}; do
    [[ ${first} -eq 1 ]] || printf ','
    printf '{"number":%s,"autoMergeRequest":{"enabledAt":"2026-01-01T00:00:00Z"}}' "${n}"
    first=0
  done
  printf ']\n'
  exit 0
fi
exit 0
EOF
  chmod +x "${STUB_DIR}/gh"
  export PATH="${STUB_DIR}:${PATH}"
  export ARMED=""
}

# ---- helpers ----

ack_path_for() {
  # Mirror lib/checkpoint.sh: sha256(cmd) first 16 hex; ack lives at
  # $TMPDIR/claude-checkpoint-<slug>-<session>-<hash>.ack
  local cmd="$1" hash
  hash="$(printf '%s' "${cmd}" | sha256sum | awk '{print substr($1, 1, 16)}')"
  echo "${TMPDIR}/claude-checkpoint-enforce-serial-merge-gate-${CLAUDE_SESSION_ID}-${hash}.ack"
}

run_hook() {
  run "$(hook enforce_serial_merge_gate.sh)" \
    <<< "{\"tool_input\":{\"command\":\"$1\"},\"cwd\":\"${PWD}\"}"
}

# ---- positive: 1st arm passes ----

@test "silent on first arm when repo has no already-armed PR" {
  export ARMED=""
  run_hook "gh pr merge 775 --repo ycpss91255-docker/base --auto --squash"
  assert_silent
}

# ---- positive: 2nd same-repo arm blocks ----

@test "denies second same-repo arm with a data-rich message" {
  export ARMED="773 774"
  run_hook "gh pr merge 775 --repo ycpss91255-docker/base --auto --squash"
  assert_permission_decision "deny"
  local reason
  reason="$(echo "${output}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
  [[ "${reason}" == *"ycpss91255-docker/base"* ]] || { echo "want repo, got: ${reason}"; return 1; }
  [[ "${reason}" == *"#773"* && "${reason}" == *"#774"* ]] || { echo "want armed list, got: ${reason}"; return 1; }
  [[ "${reason}" == *"775"* ]] || { echo "want this-pr, got: ${reason}"; return 1; }
}

@test "deny message contains ready-to-paste serial-merge.sh command" {
  export ARMED="773 774"
  run_hook "gh pr merge 775 --repo ycpss91255-docker/base --auto --squash"
  assert_permission_decision "deny"
  local reason
  reason="$(echo "${output}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
  [[ "${reason}" == *"serial-merge.sh ycpss91255-docker/base 773 774 775"* ]] || {
    echo "want ready-to-paste serial-merge command, got: ${reason}"; return 1; }
}

@test "deny writes a checkpoint markdown" {
  export ARMED="773"
  run_hook "gh pr merge 775 --repo ycpss91255-docker/base --auto --squash"
  assert_permission_decision "deny"
  local md_count
  md_count="$(find "${TMPDIR}" -maxdepth 1 -name 'claude-checkpoint-enforce-serial-merge-gate-*.md' | wc -l)"
  [[ "${md_count}" -ge 1 ]] || { echo "expected a checkpoint .md, got ${md_count}"; return 1; }
}

# ---- short-repo default-owner expansion ----

@test "short repo name expands to default owner in the message" {
  export ARMED="773"
  run_hook "gh pr merge 775 --repo base --auto --squash"
  assert_permission_decision "deny"
  local reason
  reason="$(echo "${output}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
  [[ "${reason}" == *"ycpss91255-docker/base"* ]] || { echo "want expanded owner, got: ${reason}"; return 1; }
}

# ---- idempotent re-arm: exclude the PR being armed ----

@test "excludes the PR being armed from the armed count (idempotent re-arm)" {
  export ARMED="775"
  run_hook "gh pr merge 775 --repo ycpss91255-docker/base --auto --squash"
  assert_silent
}

# ---- ack-bypass ----

@test "allows same command after ack file exists" {
  export ARMED="773 774"
  local cmd="gh pr merge 775 --repo ycpss91255-docker/base --auto --squash"
  local ack
  ack="$(ack_path_for "${cmd}")"
  : > "${ack}"
  run_hook "${cmd}"
  assert_permission_decision "allow"
  local reason
  reason="$(echo "${output}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
  [[ "${reason}" == *"previously acked"* ]] || { echo "want acked reason, got: ${reason}"; return 1; }
}

@test "ack for a different command does NOT bypass deny" {
  export ARMED="773 774"
  local other_ack
  other_ack="$(ack_path_for "gh pr merge 999 --repo ycpss91255-docker/base --auto")"
  : > "${other_ack}"
  run_hook "gh pr merge 775 --repo ycpss91255-docker/base --auto --squash"
  assert_permission_decision "deny"
}

# ---- SERIAL_MERGE bypass ----

@test "SERIAL_MERGE=1 env bypasses the gate" {
  export ARMED="773 774"
  export SERIAL_MERGE=1
  run_hook "gh pr merge 775 --repo ycpss91255-docker/base --auto --squash"
  assert_silent
}

@test "SERIAL_MERGE=1 inline command prefix bypasses the gate" {
  export ARMED="773 774"
  run_hook "SERIAL_MERGE=1 gh pr merge 775 --repo ycpss91255-docker/base --auto --squash"
  assert_silent
}

# ---- scope: non-auto and unrelated commands ----

@test "silent on non-auto gh pr merge (not an arm)" {
  export ARMED="773 774"
  run_hook "gh pr merge 775 --repo ycpss91255-docker/base --squash"
  assert_silent
}

@test "silent on unrelated command (git status)" {
  export ARMED="773 774"
  run_hook "git status"
  assert_silent
}

@test "silent on gh pr view (read-only)" {
  export ARMED="773 774"
  run_hook "gh pr view 775 --repo ycpss91255-docker/base --json state"
  assert_silent
}

@test "silent on empty command" {
  run_hook ""
  assert_silent
}
