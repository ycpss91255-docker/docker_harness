#!/usr/bin/env bats

load '../lib/test_helper'

# check-base-delivery.sh answers the question `.base/.version` cannot:
# not "which release is this repo pinned to" but "did the files that
# release installs actually arrive". Every one of those files reaches a
# consumer through init.sh, which runs only during an upgrade, so a repo
# that cannot upgrade silently carries none of them -- the state the
# base-version monitor sat in, in every repo, unreported, for months.
#
# The network is the one thing these specs do not exercise. Both boundaries
# are injected: BASE_INIT names the command asked for the expected manifest
# (really base's init.sh --list-installed-paths) and DELIVERY_PROBE names
# the command asked what a repo contains (really `gh api`). Everything
# between them -- roster reading, manifest derivation, the comparison, the
# report and the exit status -- runs here with no network at all.

setup() {
  STUB_DIR="$(mktemp -d)"
  export ROSTER_FILE="${STUB_DIR}/roster.tsv"
  export BASE_INIT="${STUB_DIR}/fake-init.sh"
  export DELIVERY_PROBE="${STUB_DIR}/fake-probe.sh"
}

teardown() {
  rm -rf "${STUB_DIR}"
}

# write_roster <repo>:<fanout> ...
#   A roster in the real column order, so the shared reader parses it the
#   same way it parses the real file.
write_roster() {
  {
    printf '# test roster\n'
    local spec repo fanout
    for spec in "$@"; do
      repo="${spec%%:*}"
      fanout="${spec#*:}"
      printf '%s\t-\t%s\tno\tyes\t-\ttest row\n' "${repo}" "${fanout}"
    done
  } > "${ROSTER_FILE}"
}

# write_manifest <path> ...
#   Stand in for `init.sh --list-installed-paths`.
write_manifest() {
  {
    printf '#!/usr/bin/env bash\n'
    local p
    for p in "$@"; do
      printf 'printf %%s\\\\n %s\n' "${p}"
    done
  } > "${BASE_INIT}"
  chmod +x "${BASE_INIT}"
}

# write_probe <repo>="<path> <path> ..." ...
#   Stand in for the remote tree read. A repo absent from the map exits 1,
#   which is how "the probe could not see this repo" reaches the report.
write_probe() {
  local map="${STUB_DIR}/trees"
  : > "${map}"
  local kv
  for kv in "$@"; do
    printf '%s\n' "${kv}" >> "${map}"
  done
  cat > "${DELIVERY_PROBE}" <<'SHIM'
#!/usr/bin/env bash
repo="$1"
map="$(dirname "$0")/trees"
while IFS='=' read -r name paths; do
  if [[ "${name}" == "${repo}" ]]; then
    tr ' ' '\n' <<< "${paths}"
    exit 0
  fi
done < "${map}"
exit 1
SHIM
  chmod +x "${DELIVERY_PROBE}"
}

# A consumer carrying everything, and one carrying only the subtree marker.
COMPLETE=".base/.version justfile .github/workflows/base-version-monitor.yaml"
BARE=".base/.version justfile"

@test "--help prints usage and exits 0" {
  run "$(script check-base-delivery.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--scope"
}

@test "unknown arg exits 2" {
  run "$(script check-base-delivery.sh)" --bogus
  assert_failure 2
  assert_output --partial "unknown arg"
}

@test "an empty selection is a failed audit, not a passed one" {
  write_roster
  write_manifest justfile
  write_probe
  run "$(script check-base-delivery.sh)"
  assert_failure 2
  assert_output --partial "no repos selected"
}

@test "the expected paths come from the manifest command, not a local copy" {
  write_roster app_one:active
  write_manifest justfile .github/workflows/base-version-monitor.yaml
  write_probe "app_one=${COMPLETE}"
  run "$(script check-base-delivery.sh)"
  assert_success
  assert_output --partial "2 paths"
}

@test "a manifest command that prints nothing aborts rather than pass every repo" {
  write_roster app_one:active
  printf '#!/usr/bin/env bash\nexit 0\n' > "${BASE_INIT}"
  chmod +x "${BASE_INIT}"
  write_probe "app_one=${BARE}"
  run "$(script check-base-delivery.sh)"
  assert_failure 2
  assert_output --partial "manifest"
}

@test "a repo missing an installed file is reported and exits 1" {
  write_roster app_one:active
  write_manifest justfile .github/workflows/base-version-monitor.yaml
  write_probe "app_one=${BARE}"
  run "$(script check-base-delivery.sh)"
  assert_failure 1
  assert_output --partial ".github/workflows/base-version-monitor.yaml"
  assert_output --partial "app_one"
}

@test "a repo carrying every installed file exits 0" {
  write_roster app_one:active
  write_manifest justfile .github/workflows/base-version-monitor.yaml
  write_probe "app_one=${COMPLETE}"
  run "$(script check-base-delivery.sh)"
  assert_success
}

@test "the headline counts how many consumers lack each file, worst first" {
  write_roster app_one:active app_two:active app_three:active
  write_manifest justfile .github/workflows/base-version-monitor.yaml
  write_probe \
    "app_one=${BARE}" \
    "app_two=${BARE}" \
    "app_three=${COMPLETE}"
  run "$(script check-base-delivery.sh)"
  assert_failure 1
  assert_output --partial "2 of 3"
  assert_output --partial ".github/workflows/base-version-monitor.yaml"
}

@test "the verdict names the worst gap so a scan cannot miss it" {
  write_roster app_one:active app_two:active
  write_manifest justfile .github/workflows/base-version-monitor.yaml
  write_probe "app_one=${BARE}" "app_two=${BARE}"
  run "$(script check-base-delivery.sh)"
  assert_failure 1
  assert_line --partial "VERDICT"
  assert_output --partial "base-version-monitor.yaml"
}

@test "a repo with no .base subtree is not counted as a delivery failure" {
  write_roster app_one:active tooling:n-a
  write_manifest justfile .github/workflows/base-version-monitor.yaml
  write_probe "app_one=${COMPLETE}" "tooling=README.md"
  run "$(script check-base-delivery.sh)"
  assert_success
  assert_output --partial "tooling"
  assert_output --partial "no .base"
}

@test "the .base version each repo is pinned to is reported alongside the gaps" {
  write_roster app_one:active
  write_manifest justfile
  write_probe "app_one=${COMPLETE}"
  run "$(script check-base-delivery.sh)"
  assert_success
  assert_output --partial "app_one"
}

@test "a repo the probe cannot read is reported as UNREADABLE and fails the audit" {
  write_roster app_one:active gone:active
  write_manifest justfile
  write_probe "app_one=${COMPLETE}"
  run "$(script check-base-delivery.sh)"
  assert_failure 1
  assert_output --partial "gone"
  assert_output --partial "UNREADABLE"
}

@test "--scope narrows to one fanout state" {
  write_roster app_one:active app_two:parked
  write_manifest justfile
  write_probe "app_one=${COMPLETE}" "app_two=${BARE}"
  run "$(script check-base-delivery.sh)" --scope active
  assert_success
  assert_output --partial "app_one"
  refute_output --partial "app_two"
}

@test "--only narrows to named repos, accepting a roster path or a bare name" {
  write_roster app_one:active app_two:active
  write_manifest justfile
  write_probe "app_one=${COMPLETE}" "app_two=${COMPLETE}"
  run "$(script check-base-delivery.sh)" --only app/app_two
  assert_success
  assert_output --partial "app_two"
  refute_output --partial "app_one"
}

@test "--skip drops named repos" {
  write_roster app_one:active app_two:active
  write_manifest justfile
  write_probe "app_one=${COMPLETE}" "app_two=${BARE}"
  run "$(script check-base-delivery.sh)" --skip app_two
  assert_success
  refute_output --partial "app_two"
}

@test "--list-repos prints the effective selection without probing anything" {
  write_roster app_one:active app_two:parked
  write_manifest justfile
  printf '#!/usr/bin/env bash\nexit 99\n' > "${DELIVERY_PROBE}"
  chmod +x "${DELIVERY_PROBE}"
  run "$(script check-base-delivery.sh)" --list-repos
  assert_success
  assert_line "app_one"
  assert_line "app_two"
}

@test "--manifest reads the expected paths from a file instead of running init.sh" {
  write_roster app_one:active
  printf '#!/usr/bin/env bash\nexit 99\n' > "${BASE_INIT}"
  chmod +x "${BASE_INIT}"
  printf '%s\n' justfile > "${STUB_DIR}/manifest.txt"
  write_probe "app_one=${COMPLETE}"
  run "$(script check-base-delivery.sh)" --manifest "${STUB_DIR}/manifest.txt"
  assert_success
  assert_output --partial "1 paths"
}
