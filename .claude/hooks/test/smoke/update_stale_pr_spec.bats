#!/usr/bin/env bats

load '../lib/test_helper'

# update-stale-pr.sh (issue #221) refreshes a stale PR by merging
# origin/<base> into the branch and pushing NORMALLY -- never rebase,
# never force. It stubs `gh` (and, for the merge-path assertion, `git`)
# via PATH; the script never touches network / refs in these tests. We
# validate arg parsing, exit codes, the worktree-resolver, --dry-run
# (no mutation), and that the mutation path invokes `git merge` (not
# rebase / force).

setup() {
  STUB_DIR="$(mktemp -d)"
  WORKSPACE="$(mktemp -d)"
  mkdir -p "${WORKSPACE}/worktree"
  export PATH="${STUB_DIR}:${PATH}"
  export WORKSPACE_DIR="${WORKSPACE}"
}

teardown() {
  rm -rf "${STUB_DIR}" "${WORKSPACE}"
  unset WORKSPACE_DIR
}

# stub_gh <json> — gh shim that echoes the given JSON for any args.
stub_gh() {
  printf '%s' "$1" > "${STUB_DIR}/gh_resp"
  cat > "${STUB_DIR}/gh" <<EOF
#!/usr/bin/env bash
cat "${STUB_DIR}/gh_resp"
EOF
  chmod +x "${STUB_DIR}/gh"
}

stub_gh_empty() {
  cat > "${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${STUB_DIR}/gh"
}

# stub_git_logger — a `git` shim that appends its args to git_calls and
# exits 0 (a clean merge). Used to assert the mutation path without a
# real repo. Only safe with an explicit --worktree so the script never
# needs git for worktree resolution.
stub_git_logger() {
  : > "${STUB_DIR}/git_calls"
  cat > "${STUB_DIR}/git" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "${STUB_DIR}/git_calls"
exit 0
EOF
  chmod +x "${STUB_DIR}/git"
}

# mk_worktree <branch> — create a fake worktree dir whose
# `git branch --show-current` returns <branch>.
mk_worktree() {
  local branch="$1"
  local dir="${WORKSPACE}/worktree/test-wt-${branch//\//-}"
  mkdir -p "${dir}"
  (
    cd "${dir}" || exit 1
    git init -q -b main >/dev/null
    git config user.email t@t
    git config user.name t
    echo init > README
    git add README >/dev/null
    git commit -q -m init
    git checkout -q -b "${branch}"
  )
  printf '%s\n' "${dir}"
}

# ------------------------------------------------------------------
# Argument validation
# ------------------------------------------------------------------

@test "--help exits 0 and prints usage" {
  run "$(script update-stale-pr.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "update-stale-pr.sh <pr>"
}

@test "missing <pr> exits 3" {
  run "$(script update-stale-pr.sh)" --dry-run
  assert_failure 3
  assert_output --partial "missing <pr>"
}

@test "non-numeric <pr> exits 3" {
  run "$(script update-stale-pr.sh)" --dry-run foo
  assert_failure 3
  assert_output --partial "invalid <pr>"
}

@test "unknown flag exits 3" {
  run "$(script update-stale-pr.sh)" --bogus 42
  assert_failure 3
  assert_output --partial "unknown flag"
}

@test "duplicate positional exits 3" {
  run "$(script update-stale-pr.sh)" --dry-run 42 99
  assert_failure 3
  assert_output --partial "unexpected arg"
}

# ------------------------------------------------------------------
# Pre-condition failures
# ------------------------------------------------------------------

@test "gh failure (PR not found) exits 3" {
  stub_gh_empty
  run "$(script update-stale-pr.sh)" --dry-run 42 --repo a/b
  assert_failure 3
  assert_output --partial "not found"
}

@test "non-OPEN PR exits 3" {
  stub_gh '{"headRefName":"feat/x","baseRefName":"main","state":"MERGED"}'
  run "$(script update-stale-pr.sh)" --dry-run 42 --repo a/b
  assert_failure 3
  assert_output --partial "MERGED"
  assert_output --partial "nothing to update"
}

@test "no matching worktree exits 3 with hint" {
  stub_gh '{"headRefName":"feat/nowhere","baseRefName":"main","state":"OPEN"}'
  run "$(script update-stale-pr.sh)" --dry-run 42 --repo a/b
  assert_failure 3
  assert_output --partial "no worktree found for branch"
  assert_output --partial "feat/nowhere"
  assert_output --partial "--worktree"
}

@test "--worktree pointing at non-existent path exits 3" {
  stub_gh '{"headRefName":"feat/x","baseRefName":"main","state":"OPEN"}'
  run "$(script update-stale-pr.sh)" --dry-run 42 --repo a/b --worktree /nonexistent/path
  assert_failure 3
  assert_output --partial "worktree path does not exist"
}

# ------------------------------------------------------------------
# Worktree resolution
# ------------------------------------------------------------------

@test "auto-resolves worktree by branch via WORKSPACE_DIR scan" {
  local wt
  wt="$(mk_worktree feat/found)"
  stub_gh '{"headRefName":"feat/found","baseRefName":"main","state":"OPEN"}'
  run "$(script update-stale-pr.sh)" --dry-run 42 --repo a/b
  assert_success
  assert_output --partial "updating PR #42 (feat/found) by merging origin/main"
  assert_output --partial "${wt}"
}

@test "--worktree overrides auto-resolution" {
  local wt
  wt="$(mk_worktree feat/auto)"
  local override
  override="$(mk_worktree feat/manual)"
  stub_gh '{"headRefName":"feat/auto","baseRefName":"main","state":"OPEN"}'
  run "$(script update-stale-pr.sh)" --dry-run 42 --repo a/b --worktree "${override}"
  assert_success
  assert_output --partial "${override}"
}

# ------------------------------------------------------------------
# Dry-run preview (no mutation)
# ------------------------------------------------------------------

@test "--dry-run prints planned merge commands, no fetch / merge / push" {
  mk_worktree feat/dryrun >/dev/null
  stub_gh '{"headRefName":"feat/dryrun","baseRefName":"main","state":"OPEN"}'
  run "$(script update-stale-pr.sh)" --dry-run 42 --repo a/b
  assert_success
  assert_output --partial "[dry-run] would: git -C"
  assert_output --partial "fetch origin main"
  assert_output --partial "merge origin/main"
  assert_output --partial "push"
  # Merge-update flow: never rebase, never force.
  refute_output --partial "rebase"
  refute_output --partial "force"
}

@test "--dry-run honours non-main base branch" {
  mk_worktree feat/x >/dev/null
  stub_gh '{"headRefName":"feat/x","baseRefName":"develop","state":"OPEN"}'
  run "$(script update-stale-pr.sh)" --dry-run 42 --repo a/b
  assert_success
  assert_output --partial "fetch origin develop"
  assert_output --partial "merge origin/develop"
}

# ------------------------------------------------------------------
# Mutation path invokes git merge (not rebase / force)
# ------------------------------------------------------------------

@test "clean run invokes git merge + normal push, never rebase / force" {
  # Explicit --worktree so the script never needs git for worktree
  # resolution; the git logger stub then records the mutation calls.
  local wt="${WORKSPACE}/worktree/explicit-wt"
  mkdir -p "${wt}"
  stub_gh '{"headRefName":"feat/merge","baseRefName":"main","state":"OPEN"}'
  stub_git_logger
  run "$(script update-stale-pr.sh)" 42 --repo a/b --worktree "${wt}"
  assert_success
  local calls
  calls="$(cat "${STUB_DIR}/git_calls")"
  [[ "${calls}" == *"merge origin/main"* ]] || {
    echo "expected a 'merge origin/main' call, got:" >&2
    echo "${calls}" >&2
    return 1
  }
  [[ "${calls}" == *"fetch origin main"* ]] || {
    echo "expected a 'fetch origin main' call, got:" >&2
    echo "${calls}" >&2
    return 1
  }
  # Normal push, and absolutely no rebase / force anywhere.
  [[ "${calls}" == *"push"* ]] || { echo "expected a push call, got: ${calls}" >&2; return 1; }
  [[ "${calls}" != *"rebase"* ]] || { echo "unexpected rebase in: ${calls}" >&2; return 1; }
  [[ "${calls}" != *"force"* ]] || { echo "unexpected force in: ${calls}" >&2; return 1; }
}
