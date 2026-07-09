#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  STUB_DIR="$(mktemp -d)"
  WORK_DIR="$(mktemp -d)"
  : > "${WORK_DIR}/compose.yaml"
  export STUB_DIR
  export PATH="${STUB_DIR}:${PATH}"
}

teardown() {
  rm -rf "${STUB_DIR}" "${WORK_DIR}"
}

# stub_docker — install a `docker` shim that records every invocation's
# argv to ${STUB_DIR}/docker.calls, one line per arg, blank line between
# invocations. Echoes a fixed bats-like output on stdout so the script's
# post-filter pipeline has something to chew on.
stub_docker() {
  cat > "${STUB_DIR}/docker" <<'SHIM'
#!/usr/bin/env bash
{
  for a in "$@"; do printf '%s\n' "$a"; done
  printf '\n'
} >> "${STUB_DIR}/docker.calls"
cat <<'OUT'
ok 1 thing one
not ok 2 thing two
ok 3 thing three
not ok 4 thing four
OUT
SHIM
  chmod +x "${STUB_DIR}/docker"
  : > "${STUB_DIR}/docker.calls"
}

# stub_id — return predictable uid/gid so HOST_UID/HOST_GID env values
# in `docker compose run -e` are stable.
stub_id() {
  cat > "${STUB_DIR}/id" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  -u) echo 1000 ;;
  -g) echo 2000 ;;
  *) echo 1000 ;;
esac
SHIM
  chmod +x "${STUB_DIR}/id"
}

# last_dash_c — print the value passed after the last `-c` in
# docker.calls (the inline shell command).
last_dash_c() {
  awk 'BEGIN{p=""} /^-c$/{f=1; next} f==1 { print; f=0 }' \
    "${STUB_DIR}/docker.calls"
}

# arg_after — print the value passed immediately after <flag>.
arg_after() {
  local flag="$1"
  awk -v flag="${flag}" 'BEGIN{f=0} { if (f==1) {print; f=0} if ($0==flag) f=1 }' \
    "${STUB_DIR}/docker.calls"
}

@test "--help prints usage and exits 0" {
  run "$(script run-bats-in-compose.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--service"
  assert_output --partial "--suite"
  assert_output --partial "--grep"
}

@test "unknown arg exits 2" {
  run "$(script run-bats-in-compose.sh)" --bogus
  assert_failure 2
  assert_output --partial "unknown arg"
}

@test "missing compose.yaml exits 2" {
  stub_docker
  stub_id
  EMPTY_DIR="$(mktemp -d)"
  cd "${EMPTY_DIR}"
  run "$(script run-bats-in-compose.sh)"
  assert_failure 2
  assert_output --partial "compose file not found"
  rm -rf "${EMPTY_DIR}"
}

@test "single-quote in --grep is rejected" {
  stub_docker
  stub_id
  cd "${WORK_DIR}"
  run "$(script run-bats-in-compose.sh)" --grep "no'good"
  assert_failure 2
  assert_output --partial "must not contain single quotes"
}

@test "default suite=all targets unit + integration dirs" {
  stub_docker
  stub_id
  cd "${WORK_DIR}"
  run "$(script run-bats-in-compose.sh)"
  assert_success
  local cmd
  cmd="$(last_dash_c)"
  [[ "${cmd}" == *"bats /source/test/unit/ /source/test/integration/"* ]] \
    || { echo "inner cmd: ${cmd}" >&2; return 1; }
}

@test "--suite unit narrows to /source/test/unit/" {
  stub_docker
  stub_id
  cd "${WORK_DIR}"
  run "$(script run-bats-in-compose.sh)" --suite unit
  assert_success
  local cmd
  cmd="$(last_dash_c)"
  [[ "${cmd}" == *"bats /source/test/unit/ "* ]] \
    || [[ "${cmd}" == *"bats /source/test/unit/"* && "${cmd}" != *integration* ]] \
    || { echo "inner cmd: ${cmd}" >&2; return 1; }
  [[ "${cmd}" == *integration* ]] && { echo "should not include integration: ${cmd}" >&2; return 1; }
  return 0
}

@test "--suite integration narrows to /source/test/integration/" {
  stub_docker
  stub_id
  cd "${WORK_DIR}"
  run "$(script run-bats-in-compose.sh)" --suite integration
  assert_success
  local cmd
  cmd="$(last_dash_c)"
  [[ "${cmd}" == *"bats /source/test/integration/"* ]] || { echo "inner cmd: ${cmd}" >&2; return 1; }
  [[ "${cmd}" == *"unit/"* ]] && { echo "should not include unit: ${cmd}" >&2; return 1; }
  return 0
}

@test "--suite <path> uses literal /source/<path>" {
  stub_docker
  stub_id
  cd "${WORK_DIR}"
  run "$(script run-bats-in-compose.sh)" --suite test/unit/tui_spec.bats
  assert_success
  local cmd
  cmd="$(last_dash_c)"
  [[ "${cmd}" == *"bats /source/test/unit/tui_spec.bats"* ]] || { echo "inner cmd: ${cmd}" >&2; return 1; }
}

@test "default --grep produces inner cmd with grep filter pipe" {
  stub_docker
  stub_id
  cd "${WORK_DIR}"
  run "$(script run-bats-in-compose.sh)"
  assert_success
  local cmd
  cmd="$(last_dash_c)"
  [[ "${cmd}" == *"| grep -E -- '^not ok'"* ]] \
    || { echo "inner cmd: ${cmd}" >&2; return 1; }
}

@test "--grep '' disables filter (full output)" {
  stub_docker
  stub_id
  cd "${WORK_DIR}"
  run "$(script run-bats-in-compose.sh)" --grep "" --tail 100
  assert_success
  assert_output --partial "ok 1 thing one"
  assert_output --partial "not ok 2 thing two"
  assert_output --partial "ok 3 thing three"
  assert_output --partial "not ok 4 thing four"
  local cmd
  cmd="$(last_dash_c)"
  [[ "${cmd}" == *"| grep"* ]] && { echo "should not pipe to grep: ${cmd}" >&2; return 1; }
  return 0
}

@test "--service overrides default service name" {
  stub_docker
  stub_id
  cd "${WORK_DIR}"
  run "$(script run-bats-in-compose.sh)" --service mytest
  assert_success
  grep -qx "mytest" "${STUB_DIR}/docker.calls" || { cat "${STUB_DIR}/docker.calls" >&2; return 1; }
  ! grep -qx "ci" "${STUB_DIR}/docker.calls"
}

@test "--compose-file overrides default compose.yaml" {
  stub_docker
  stub_id
  cd "${WORK_DIR}"
  : > "${WORK_DIR}/custom.yaml"
  run "$(script run-bats-in-compose.sh)" --compose-file custom.yaml
  assert_success
  local f
  f="$(arg_after -f)"
  [[ "${f}" == "custom.yaml" ]] || { echo "compose -f arg was: ${f}" >&2; return 1; }
}

@test "HOST_UID / HOST_GID env values come from id stub" {
  stub_docker
  stub_id
  cd "${WORK_DIR}"
  run "$(script run-bats-in-compose.sh)"
  assert_success
  grep -qx "HOST_UID=1000" "${STUB_DIR}/docker.calls" || { cat "${STUB_DIR}/docker.calls" >&2; return 1; }
  grep -qx "HOST_GID=2000" "${STUB_DIR}/docker.calls"
}

@test "--head N caps output to first N lines" {
  stub_docker
  stub_id
  cd "${WORK_DIR}"
  run "$(script run-bats-in-compose.sh)" --grep "" --head 2
  assert_success
  [[ "${#lines[@]}" -le 2 ]] || { echo "got ${#lines[@]} lines: ${output}" >&2; return 1; }
}
