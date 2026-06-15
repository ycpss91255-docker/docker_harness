#!/usr/bin/env bats

load '../lib/test_helper'

# enforce_wrapper_first_upgrade.sh -- PreToolUse Bash hook that DENIES direct
# `./.base/upgrade.sh` invocations when the repo has a `Makefile.ci` with an
# `upgrade` target. Replaces the older remind_make_first_upgrade.sh remind
# pattern with the `/tmp` checkpoint protocol (ADR-00000002 / #117) so the
# block can be lifted by the user via a `touch <ack-file>` ack on the same
# command (sha256(cmd) hashed).
#
# Three layers exercised:
#   - positive: invocation writes a checkpoint and denies
#   - negative: routes through make wrapper or rule N/A are silent
#   - ack-bypass: a pre-existing .ack file allows the same command

setup() {
  export TMPDIR="${BATS_TEST_TMPDIR}"
  export CLAUDE_SESSION_ID="enforce-make-first-upgrade-spec"

  REPO="$(mktemp -d)"
  cd "${REPO}"
  git init -q -b main
  git config user.email t@t
  git config user.name t
  mkdir -p .base template
  cat > Makefile.ci <<'EOF'
.PHONY: upgrade

upgrade:
	./.base/upgrade.sh $(VERSION)
EOF
  cat > .base/upgrade.sh <<'EOF'
#!/usr/bin/env bash
echo "stub upgrade.sh"
EOF
  cat > template/upgrade.sh <<'EOF'
#!/usr/bin/env bash
echo "stub legacy template/upgrade.sh"
EOF
  chmod +x .base/upgrade.sh template/upgrade.sh
  git add -A >/dev/null
  git commit -q -m init >/dev/null
  cd - >/dev/null
}

teardown() {
  rm -rf "${REPO}"
}

# ---- helpers ----

ack_path_for() {
  # Mirror lib/checkpoint.sh: sha256(cmd) first 16 hex chars; ack lives at
  # $TMPDIR/claude-checkpoint-<slug>-<session>-<hash>.ack
  local cmd="$1"
  local hash
  hash="$(printf '%s' "${cmd}" | sha256sum | awk '{print substr($1, 1, 16)}')"
  echo "${TMPDIR}/claude-checkpoint-enforce-make-first-upgrade-${CLAUDE_SESSION_ID}-${hash}.ack"
}

# ---- positive: detect + deny + write checkpoint ----

@test "denies ./.base/upgrade.sh and writes checkpoint markdown" {
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"./.base/upgrade.sh v0.18.2\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
  # Checkpoint markdown rendered at $TMPDIR/claude-checkpoint-enforce-make-first-upgrade-<session>-<hash>.md
  local md_count
  md_count="$(find "${TMPDIR}" -maxdepth 1 -name 'claude-checkpoint-enforce-make-first-upgrade-*.md' | wc -l)"
  [[ "${md_count}" -ge 1 ]] || {
    echo "expected at least one checkpoint .md in TMPDIR, got ${md_count}" >&2
    ls -la "${TMPDIR}" >&2 || true
    return 1
  }
}

@test "denies bare .base/upgrade.sh (no leading ./)" {
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\".base/upgrade.sh\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
}

@test "denies absolute path .base/upgrade.sh" {
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${REPO}/.base/upgrade.sh v0.18.3\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
}

@test "deny reason mentions canonical make wrapper" {
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"./.base/upgrade.sh v0.18.2\"},\"cwd\":\"${REPO}\"}"
  assert_success
  local reason
  reason="$(echo "${output}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
  [[ "${reason}" == *"make -f Makefile.ci upgrade"* ]] || {
    echo "expected reason to mention make wrapper, got: ${reason}" >&2
    return 1
  }
}

# ---- positive (expanded scope): legacy template/upgrade.sh ----

@test "denies ./template/upgrade.sh (legacy folder name)" {
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"./template/upgrade.sh v0.18.2\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
}

@test "denies bare template/upgrade.sh (legacy, no leading ./)" {
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"template/upgrade.sh\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
}

# ---- positive (expanded scope): raw git subtree pull ----

@test "denies git subtree pull --prefix=.base ..." {
  local cmd="git subtree pull --prefix=.base ycpss91255-docker/base.git v0.18.2 --squash"
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
}

@test "denies git subtree pull --prefix=template ... (legacy prefix)" {
  local cmd="git subtree pull --prefix=template ycpss91255-docker/base.git v0.18.2 --squash"
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
}

@test "denies git -C <repo> subtree pull --prefix=.base ... (via -C arg)" {
  local cmd="git -C ${REPO} subtree pull --prefix=.base ycpss91255-docker/base.git v0.18.2 --squash"
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"},\"cwd\":\"/tmp\"}"
  assert_permission_decision "deny"
}

@test "silent on git subtree pull with unrelated --prefix=foo" {
  local cmd="git subtree pull --prefix=foo some-remote main --squash"
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent on git subtree push --prefix=.base (push, not pull)" {
  local cmd="git subtree push --prefix=.base origin some-branch"
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

# ---- negative: silent when not applicable ----

@test "silent on make -f Makefile.ci upgrade (already going through wrapper)" {
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"make -f Makefile.ci upgrade VERSION=v0.18.2\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent when Makefile.ci absent (no make wrapper available)" {
  local repo
  repo="$(mktemp -d)"
  cd "${repo}"
  git init -q -b main
  git config user.email t@t
  git config user.name t
  mkdir -p .base
  echo "#!/bin/sh" > .base/upgrade.sh
  chmod +x .base/upgrade.sh
  git add -A >/dev/null
  git commit -q -m init >/dev/null
  cd - >/dev/null
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"./.base/upgrade.sh v0.18.2\"},\"cwd\":\"${repo}\"}"
  assert_silent
  rm -rf "${repo}"
}

@test "silent when Makefile.ci has no upgrade target" {
  cat > "${REPO}/Makefile.ci" <<'EOF'
.PHONY: test

test:
	echo test
EOF
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"./.base/upgrade.sh v0.18.2\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent on unrelated commands (git status)" {
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git status\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent on script with similar name (foo/upgrade.sh)" {
  mkdir -p "${REPO}/foo"
  echo "#!/bin/sh" > "${REPO}/foo/upgrade.sh"
  chmod +x "${REPO}/foo/upgrade.sh"
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"./foo/upgrade.sh\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent on empty command" {
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

# ---- ack-bypass: pre-existing ack file flips deny to allow ----

@test "allows same command after ack file exists" {
  local cmd="./.base/upgrade.sh v0.18.2"
  local ack
  ack="$(ack_path_for "${cmd}")"
  : > "${ack}"
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"${cmd}\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "allow"
  local reason
  reason="$(echo "${output}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
  [[ "${reason}" == *"previously acked"* ]] || {
    echo "expected reason to say 'previously acked', got: ${reason}" >&2
    return 1
  }
}

@test "ack for different command does NOT bypass deny" {
  # Ack a different (unrelated) command -- the upgrade.sh call must still deny.
  local other_ack
  other_ack="$(ack_path_for "./.base/upgrade.sh v0.99.99")"
  : > "${other_ack}"
  run "$(hook enforce_wrapper_first_upgrade.sh)" \
    <<< "{\"tool_input\":{\"command\":\"./.base/upgrade.sh v0.18.2\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
}
