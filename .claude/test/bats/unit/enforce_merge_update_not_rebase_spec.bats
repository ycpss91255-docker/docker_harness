#!/usr/bin/env bats

load '../lib/test_helper'

# enforce_merge_update_not_rebase.sh -- PreToolUse Bash hook (issue #221).
# Policy: git rebase is disallowed; stale PRs update via `git merge
# origin/main` + a normal push. Two deny surfaces:
#   1. `git rebase ...` / `git pull --rebase` (recovery flags exempt).
#   2. `git push --force*` ONLY when the branch has an open PR.
# Both denies lift via the /tmp checkpoint + touch-ACK protocol
# (ADR-00000002 / #117). The hook ALWAYS fails open on gh errors.
#
# `gh` is mocked on PATH to return a canned open-PR list (or empty / an
# error). Force-push branch resolution falls back to the cwd repo's
# current branch, so setup() seeds a real git repo on a feature branch.

setup() {
  export TMPDIR="${BATS_TEST_TMPDIR}"
  export CLAUDE_SESSION_ID="enforce-merge-update-not-rebase-spec"

  STUB_DIR="$(mktemp -d)"
  export PATH="${STUB_DIR}:${PATH}"

  # Real git repo on a feature branch -- used when the force-push command
  # carries no explicit `origin <branch>` and the hook resolves the
  # current branch via `git -C <cwd> branch --show-current`.
  REPO="$(mktemp -d)"
  (
    cd "${REPO}" || exit 1
    git init -q -b main
    git config user.email t@t
    git config user.name t
    echo init > README
    git add README >/dev/null
    git commit -q -m init
    git checkout -q -b feat/topic
  ) >/dev/null
}

teardown() {
  rm -rf "${STUB_DIR}" "${REPO}"
}

# ---- helpers ----

# stub_gh <json> -- gh shim echoing the given JSON for any args.
stub_gh() {
  printf '%s' "$1" > "${STUB_DIR}/gh_resp"
  cat > "${STUB_DIR}/gh" <<EOF
#!/usr/bin/env bash
cat "${STUB_DIR}/gh_resp"
EOF
  chmod +x "${STUB_DIR}/gh"
}

# stub_gh_fail -- gh shim that errors (unavailable), for fail-open cases.
stub_gh_fail() {
  cat > "${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${STUB_DIR}/gh"
}

# stub_gh_head <branch> <json> -- gh shim returning <json> ONLY when the
# args contain `--head <branch>`, else an empty list. Lets a test prove the
# hook resolved the RIGHT branch (e.g. HEAD -> current branch), which the
# any-args stub_gh cannot distinguish.
stub_gh_head() {
  printf '%s' "$2" > "${STUB_DIR}/gh_resp"
  cat > "${STUB_DIR}/gh" <<EOF
#!/usr/bin/env bash
if printf '%s ' "\$@" | grep -q -- '--head $1 '; then
  cat "${STUB_DIR}/gh_resp"
else
  echo '[]'
fi
EOF
  chmod +x "${STUB_DIR}/gh"
}

ack_path_for() {
  # Mirror lib/checkpoint.sh: sha256(cmd) first 16 hex chars; ack lives at
  # $TMPDIR/claude-checkpoint-<slug>-<session>-<hash>.ack
  local cmd="$1" hash
  hash="$(printf '%s' "${cmd}" | sha256sum | awk '{print substr($1, 1, 16)}')"
  echo "${TMPDIR}/claude-checkpoint-enforce-merge-update-not-rebase-${CLAUDE_SESSION_ID}-${hash}.ack"
}

# run_hook <cmd> [cwd] -- feed the hook the PreToolUse stdin JSON. Built
# with jq so a command containing double-quotes (e.g. a commit message) is
# escaped correctly rather than breaking the JSON.
run_hook() {
  local cmd="$1" cwd="${2:-${REPO}}" json
  json="$(jq -n --arg c "${cmd}" --arg d "${cwd}" \
    '{tool_input:{command:$c}, cwd:$d}')"
  run "$(hook enforce_merge_update_not_rebase.sh)" <<< "${json}"
}

# ---- surface 1: git rebase -> deny ----

@test "git rebase main -> deny" {
  run_hook "git rebase main"
  assert_permission_decision "deny"
}

@test "git rebase -i HEAD~3 -> deny" {
  run_hook "git rebase -i HEAD~3"
  assert_permission_decision "deny"
}

@test "git -C some/dir rebase origin/main -> deny" {
  run_hook "git -C some/dir rebase origin/main"
  assert_permission_decision "deny"
}

@test "git pull --rebase -> deny" {
  run_hook "git pull --rebase"
  assert_permission_decision "deny"
}

# ---- surface 1: recovery flags are exempt (silent) ----

@test "git rebase --abort -> silent (recovery exempt)" {
  run_hook "git rebase --abort"
  assert_silent
}

@test "git rebase --continue -> silent (recovery exempt)" {
  run_hook "git rebase --continue"
  assert_silent
}

@test "git rebase --skip -> silent (recovery exempt)" {
  run_hook "git rebase --skip"
  assert_silent
}

# ---- surface 2: force-push WITH an open PR -> deny ----

@test "git push --force on branch WITH open PR -> deny" {
  stub_gh '[{"number":5}]'
  run_hook "git push --force"
  assert_permission_decision "deny"
}

@test "git push --force-with-lease origin feat/x WITH open PR -> deny" {
  stub_gh '[{"number":7}]'
  run_hook "git push --force-with-lease origin feat/x"
  assert_permission_decision "deny"
}

# ---- surface 2: fail-open (silent) ----

@test "git push --force on branch with NO open PR -> silent (fail-open)" {
  stub_gh '[]'
  run_hook "git push --force"
  assert_silent
}

@test "git push --force when gh errors / unavailable -> silent (fail-open)" {
  stub_gh_fail
  run_hook "git push --force"
  assert_silent
}

# ---- silent pass-through ----

@test "plain git push (no force) -> silent" {
  stub_gh '[{"number":5}]'
  run_hook "git push"
  assert_silent
}

@test "non-git command (ls) -> silent" {
  run_hook "ls -la"
  assert_silent
}

@test "empty command -> silent" {
  run_hook ""
  assert_silent
}

# ---- ack-bypass: pre-existing ack file flips deny to allow ----

@test "git rebase after ack file exists -> allow" {
  local cmd="git rebase main"
  local ack
  ack="$(ack_path_for "${cmd}")"
  : > "${ack}"
  run_hook "${cmd}"
  assert_permission_decision "allow"
  local reason
  reason="$(echo "${output}" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
  [[ "${reason}" == *"previously acked"* ]] || {
    echo "expected reason to say 'previously acked', got: ${reason}" >&2
    return 1
  }
}

# ---- boundary cases: false-positives + bypass holes (review of #221) ----

@test "B1: force flag from a chained non-git command does not trip force-push" {
  # `-f` belongs to `docker build`, not the `git push` segment.
  stub_gh '[{"number":5}]'
  run_hook 'git push origin main && docker build -f Dockerfile .'
  assert_silent
}

@test "B2: git push -f origin HEAD resolves HEAD to the current branch and denies" {
  # gh returns a PR ONLY for feat/topic; if the hook used the literal 'HEAD'
  # as --head it would find nothing and wrongly allow.
  stub_gh_head 'feat/topic' '[{"number":5}]'
  run_hook 'git push -f origin HEAD'
  assert_permission_decision "deny"
}

@test "N1: global -c option before rebase is still denied" {
  run_hook 'git -c rebase.autostash=true rebase main'
  assert_permission_decision "deny"
}

@test "N1: global -c option before push --force is still gated" {
  stub_gh '[{"number":5}]'
  run_hook 'git -c foo=bar push --force'
  assert_permission_decision "deny"
}

@test "N2: rebase inside a commit message is not treated as a rebase" {
  run_hook 'git commit -m "feat: disallow git rebase org-wide"'
  assert_silent
}

@test "N3: +refspec force-push on an open-PR branch is denied" {
  stub_gh '[{"number":5}]'
  run_hook 'git push origin +feat/topic'
  assert_permission_decision "deny"
}
