#!/usr/bin/env bats

# Covers the single downstream roster (refs #272).
#
# The roster lived in four places -- `batch-base-upgrade.sh`'s DEFAULT_REPOS,
# `check-template-versions.sh`'s DEFAULT_REPOS, `sync-org-repo-settings.sh`'s
# ALL_REPOS, and an inline `for repo in ...` in `.claude/commands/pr.md` --
# and they had already diverged: the upgrader listed `app/realsense_ros2` as
# active while the verifier had it commented out with a contradicting note. So
# the documented fanout step "verify each downstream main is at the target tag"
# iterated 2 repos while the upgrader had opened PRs for 3, and `--expect`
# exited 0 because it only ever loops over its own list.
#
# Two properties are asserted here, because fixing one without the other
# leaves the same hole:
#   1. STRUCTURAL -- exactly one file declares the roster, and everything else
#      reads it. Divergence needs two copies; one copy cannot diverge.
#   2. NON-VACUOUS -- a verification pass over an empty list is a failure, not
#      a pass. A verifier that cannot fail for the repo most likely to need it
#      is worse than no verifier.

load '../lib/test_helper'

ROSTER="${SCRIPTS_DIR:-}/lib/roster.tsv"

setup() {
  ROSTER="${SCRIPTS_DIR}/lib/roster.tsv"
  CURL_STUB_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${CURL_STUB_DIR}"
}

# roster_lib -- absolute path to the reader library.
roster_lib() { echo "${SCRIPTS_DIR}/lib/roster.sh"; }

@test "the roster is a data file, not a list embedded in a script" {
  [ -f "${ROSTER}" ] || fail "no roster data file at ${ROSTER}"
  [ -f "$(roster_lib)" ] || fail "no roster reader at $(roster_lib)"
}

@test "roster_fanout_paths active lists the repos the fanout really touches" {
  run bash -c "source '$(roster_lib)'; roster_fanout_paths active"
  assert_success
  assert_line 'app/realsense_ros2'
  assert_line 'env/ros_distro'
  assert_line 'env/ros2_distro'
}

@test "roster_fanout_paths parked lists the rest, and the two sets are disjoint" {
  local active parked
  active="$(bash -c "source '$(roster_lib)'; roster_fanout_paths active")"
  parked="$(bash -c "source '$(roster_lib)'; roster_fanout_paths parked")"
  [ -n "${parked}" ] || fail "no parked repos -- the roster lost its lifecycle state"
  local p
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    printf '%s\n' "${active}" | grep -qxF -- "${p}" \
      && fail "'${p}' is listed both active and parked"
  done <<< "${parked}"
  return 0
}

@test "roster_settings_repos covers the org, and names both base and template" {
  # `template` is NOT the pre-rename name of `base`: after base was renamed,
  # a fresh `template` repo was created as the GitHub Template used to
  # bootstrap downstream repos. Both are live and both need settings synced,
  # so the roster has to record that or somebody deletes one as "stale".
  run bash -c "source '$(roster_lib)'; roster_settings_repos"
  assert_success
  assert_line 'base'
  assert_line 'template'
  assert_line 'docker_harness'
  assert_line '.github'
  refute_line 'github_runner'
}

@test "roster_required_check answers per repo, empty for .github" {
  run bash -c "source '$(roster_lib)'; roster_required_check base"
  assert_success
  assert_output 'ci-rollup'

  run bash -c "source '$(roster_lib)'; roster_required_check ros_distro"
  assert_output 'ci-passed'

  run bash -c "source '$(roster_lib)'; roster_required_check .github"
  assert_output ''

  run bash -c "source '$(roster_lib)'; roster_required_check ai_agent"
  assert_output 'call-docker-build / docker-build'
}

@test "one roster: a second repo list needs an explicit, reasoned exemption" {
  # The divergence detector, and the reason it is shaped as an exemption rather
  # than a ban: the executed one-shot fanouts (`batch-gitignore-fix.sh` and
  # friends) legitimately keep the list they RAN against -- that is a record,
  # not a scope, and rewriting it from the roster would rewrite history. Every
  # such file says so on the line above its array. Everything live reads the
  # roster, so it has nothing to diverge from.
  local offenders="" f
  for f in "${SCRIPTS_DIR}"/*.sh; do
    grep -qE '^[[:space:]]*(readonly )?[A-Z_]*REPOS=\([^)]*$' "${f}" || continue
    grep -q '# roster-exempt:' "${f}" && continue
    offenders+="${f}"$'\n'
  done
  [[ -z "${offenders}" ]] || fail "these scripts declare their own repo list with no '# roster-exempt: <why>':
${offenders}"
}

@test "one roster: /pr's fan-out step points at the script, not a fourth copy" {
  run grep -nE 'for repo in .*(env|app|agent)/' "${PROJECT_ROOT}/.claude/commands/pr.md"
  assert_failure
  run grep -c 'batch-base-upgrade.sh' "${PROJECT_ROOT}/.claude/commands/pr.md"
  assert_success
}

@test "verifier and upgrader iterate the same list" {
  local verifier upgrader
  verifier="$("$(script check-template-versions.sh)" --list-repos)"
  upgrader="$("$(script batch-base-upgrade.sh)" --list-repos)"
  [ -n "${verifier}" ] || fail "verifier listed no repos"
  [ "${verifier}" = "${upgrader}" ] || fail "the fanout verifier and the upgrader disagree:
verifier:
${verifier}
upgrader:
${upgrader}"
}

@test "--expect over an empty selection fails instead of passing vacuously" {
  # `--skip`-ing everything used to leave the loop with nothing to check and
  # still exit 0. Same shape as the original bug (a verifier that structurally
  # cannot fail), just reachable from the command line.
  local all
  all="$("$(script check-template-versions.sh)" --list-repos | paste -sd, -)"
  run "$(script check-template-versions.sh)" --skip "${all}" --expect v0.0.0
  assert_failure
  assert_output --partial 'no repos'
}
