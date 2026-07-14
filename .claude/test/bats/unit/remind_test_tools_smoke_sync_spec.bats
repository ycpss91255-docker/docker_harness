#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  TMPDIR="$(mktemp -d)"
  mkdir -p "${TMPDIR}/dockerfile" "${TMPDIR}/.github/workflows"
}

teardown() {
  rm -rf "${TMPDIR}"
}

# Helper — write a minimal Dockerfile.test-tools with the given final-stage
# `apk add --no-cache` payload.
_write_dockerfile() {
  local pkgs="$1"
  cat > "${TMPDIR}/dockerfile/Dockerfile.test-tools" <<EOF
FROM alpine:latest AS bats-extensions
RUN apk add --no-cache git

FROM alpine:latest
RUN apk add --no-cache ${pkgs}
EOF
}

# Helper — write a release-test-tools.yaml with a smoke step verifying
# each command in the comma-separated list.
_write_yaml() {
  local cmds="$1"
  {
    echo "jobs:"
    echo "  release-test-tools:"
    echo "    runs-on: ubuntu-latest"
    echo "    steps:"
    echo "      - name: Smoke test pushed image"
    echo "        run: |"
    if [[ -n "${cmds}" ]]; then
      local IFS=','
      for cmd in ${cmds}; do
        echo "          docker run --rm \"\${image}\" ${cmd# }"
      done
    fi
    echo "      - name: Done"
    echo "        run: echo done"
  } > "${TMPDIR}/.github/workflows/release-test-tools.yaml"
}

@test "fires on Dockerfile.test-tools edit, listing apk packages and smoke commands" {
  _write_dockerfile "bash parallel git"
  _write_yaml "bats --version, parallel --version"
  run "$(hook remind_test_tools_smoke_sync.sh)" \
    <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/dockerfile/Dockerfile.test-tools\"}}"
  assert_message_contains "bash parallel git"
  assert_message_contains "bats --version"
  assert_message_contains "parallel --version"
}

@test "lists every package on the final stage apk add line" {
  _write_dockerfile "bash parallel git git-subtree ca-certificates grep coreutils"
  _write_yaml "bats --version"
  run "$(hook remind_test_tools_smoke_sync.sh)" \
    <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/dockerfile/Dockerfile.test-tools\"}}"
  assert_message_contains "git-subtree"
  assert_message_contains "coreutils"
}

@test "ignores apk add lines from non-final stages" {
  cat > "${TMPDIR}/dockerfile/Dockerfile.test-tools" <<'EOF'
FROM alpine:latest AS bats-extensions
RUN apk add --no-cache curl-stage-only

FROM alpine:latest
RUN apk add --no-cache bash parallel
EOF
  _write_yaml "bats --version"
  run "$(hook remind_test_tools_smoke_sync.sh)" \
    <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/dockerfile/Dockerfile.test-tools\"}}"
  assert_message_contains "bash parallel"
  refute_output --partial "curl-stage-only"
}

@test "silent when sibling release-test-tools.yaml is missing" {
  _write_dockerfile "bash"
  # No yaml on purpose.
  run "$(hook remind_test_tools_smoke_sync.sh)" \
    <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/dockerfile/Dockerfile.test-tools\"}}"
  assert_silent
}

@test "silent on unrelated Dockerfile" {
  echo "FROM alpine" > "${TMPDIR}/Dockerfile"
  run "$(hook remind_test_tools_smoke_sync.sh)" \
    <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/Dockerfile\"}}"
  assert_silent
}

@test "silent when Dockerfile.test-tools has no final-stage apk add" {
  cat > "${TMPDIR}/dockerfile/Dockerfile.test-tools" <<'EOF'
FROM alpine:latest AS bats-extensions
RUN apk add --no-cache git

FROM alpine:latest
COPY --from=bats-extensions /bats /usr/lib/bats
EOF
  _write_yaml "bats --version"
  run "$(hook remind_test_tools_smoke_sync.sh)" \
    <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/dockerfile/Dockerfile.test-tools\"}}"
  assert_silent
}

@test "handles empty smoke step gracefully" {
  _write_dockerfile "bash parallel"
  _write_yaml ""
  run "$(hook remind_test_tools_smoke_sync.sh)" \
    <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/dockerfile/Dockerfile.test-tools\"}}"
  assert_message_contains "bash parallel"
  assert_message_contains "(none)"
}
