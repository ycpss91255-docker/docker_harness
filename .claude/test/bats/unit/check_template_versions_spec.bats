#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  CURL_STUB_DIR="$(mktemp -d)"
  export PATH="${CURL_STUB_DIR}:${PATH}"
}

teardown() {
  rm -rf "${CURL_STUB_DIR}"
}

# stub_curl_map <reponame=ver> [reponame=ver ...] — install a `curl` shim
# that, given a raw.githubusercontent.com/<org>/<repo>/main/.base/.version
# URL, prints the mapped version (and exits 0). Repos absent from the map
# cause curl to exit 22 (HTTP error), simulating a missing tag.
stub_curl_map() {
  local mapfile="${CURL_STUB_DIR}/.versions"
  : > "${mapfile}"
  local kv
  for kv in "$@"; do
    printf '%s\n' "${kv}" >> "${mapfile}"
  done
  cat > "${CURL_STUB_DIR}/curl" <<'SHIM'
#!/usr/bin/env bash
# Args order from script: -fsSL --max-time 10 <url>
url="${@: -1}"
# Extract reponame between /<org>/ and /main/
repo="${url#https://raw.githubusercontent.com/}"
repo="${repo%%/main/.base/.version}"
repo="${repo#*/}"
mapfile="$(dirname "$0")/.versions"
while IFS='=' read -r name ver; do
  if [[ "${name}" == "${repo}" ]]; then
    printf '%s' "${ver}"
    exit 0
  fi
done < "${mapfile}"
exit 22
SHIM
  chmod +x "${CURL_STUB_DIR}/curl"
}

@test "--help prints usage and exits 0" {
  run "$(script check-template-versions.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--only"
  assert_output --partial "--expect"
}

@test "unknown arg exits 2" {
  run "$(script check-template-versions.sh)" --bogus
  assert_failure 2
  assert_output --partial "unknown arg"
}

@test "--only narrows to listed repos and prints versions" {
  stub_curl_map ai_agent=v0.12.3 claude_code=v0.12.3
  run "$(script check-template-versions.sh)" \
    --only agent/ai_agent,agent/claude_code
  assert_success
  assert_output --partial "ai_agent"
  assert_output --partial "v0.12.3"
  assert_output --partial "claude_code"
  refute_output --partial "ros2_humble"
}

@test "missing version maps to MISSING" {
  stub_curl_map  # empty map → all curls exit 22
  run "$(script check-template-versions.sh)" --only agent/ai_agent
  assert_success
  assert_output --partial "ai_agent"
  assert_output --partial "MISSING"
}

@test "--expect matches all → exit 0" {
  stub_curl_map ai_agent=v0.12.3 claude_code=v0.12.3
  run "$(script check-template-versions.sh)" \
    --only agent/ai_agent,agent/claude_code \
    --expect v0.12.3
  assert_success
}

@test "--expect mismatch → exit 1" {
  stub_curl_map ai_agent=v0.12.3 claude_code=v0.12.2
  run "$(script check-template-versions.sh)" \
    --only agent/ai_agent,agent/claude_code \
    --expect v0.12.3
  assert_failure 1
  assert_output --partial "do not match"
}

@test "--skip removes listed repo from default iteration" {
  stub_curl_map ai_agent=v0.12.3 claude_code=v0.12.3
  run "$(script check-template-versions.sh)" \
    --only agent/ai_agent,agent/claude_code \
    --skip agent/claude_code
  assert_success
  assert_output --partial "ai_agent"
  refute_output --partial "claude_code"
}
