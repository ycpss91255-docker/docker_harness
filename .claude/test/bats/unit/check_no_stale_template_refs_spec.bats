#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  TMPDIR="$(mktemp -d)"
  mkdir -p "${TMPDIR}/.base/script/docker"
  mkdir -p "${TMPDIR}/.base/dockerfile"
  mkdir -p "${TMPDIR}/archive/template/script/docker"
}

teardown() {
  rm -rf "${TMPDIR}"
}

@test "fires on template/script/docker reference in .base/script/docker/*.sh" {
  cat > "${TMPDIR}/.base/script/docker/build.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/../../template/script/docker/_lib.sh"
EOF
  run "$(hook check_no_stale_template_refs.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/.base/script/docker/build.sh\"}}"
  assert_message_contains "Stale template/ reference"
}

@test "fires on template/init.sh reference" {
  cat > "${TMPDIR}/.base/script/docker/run.sh" <<'EOF'
echo "see template/init.sh for details"
EOF
  run "$(hook check_no_stale_template_refs.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/.base/script/docker/run.sh\"}}"
  assert_message_contains "Stale template/ reference"
}

@test "fires on template/upgrade.sh reference" {
  cat > "${TMPDIR}/.base/script/docker/exec.sh" <<'EOF'
./template/upgrade.sh
EOF
  run "$(hook check_no_stale_template_refs.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/.base/script/docker/exec.sh\"}}"
  assert_message_contains "Stale template/ reference"
}

@test "fires on template/dockerfile/ reference" {
  cat > "${TMPDIR}/.base/script/docker/build.sh" <<'EOF'
COPY template/dockerfile/Dockerfile.example .
EOF
  run "$(hook check_no_stale_template_refs.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/.base/script/docker/build.sh\"}}"
  assert_message_contains "Stale template/ reference"
}

@test "fires on template/Makefile reference" {
  cat > "${TMPDIR}/.base/script/docker/Makefile" <<'EOF'
include template/Makefile.ci
EOF
  run "$(hook check_no_stale_template_refs.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/.base/script/docker/Makefile\"}}"
  assert_message_contains "Stale template/ reference"
}

@test "fires on Dockerfile under .base/" {
  cat > "${TMPDIR}/.base/dockerfile/Dockerfile.example" <<'EOF'
COPY template/config/bashrc /etc/
EOF
  run "$(hook check_no_stale_template_refs.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/.base/dockerfile/Dockerfile.example\"}}"
  assert_message_contains "Stale template/ reference"
}

@test "silent after s|template/|.base/|g" {
  cat > "${TMPDIR}/.base/script/docker/build.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/../../.base/script/docker/_lib.sh"
EOF
  run "$(hook check_no_stale_template_refs.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/.base/script/docker/build.sh\"}}"
  assert_silent
}

@test "silent on literal template/ in archive/ (not under .base/)" {
  cat > "${TMPDIR}/archive/template/script/docker/_lib.sh" <<'EOF'
echo "this file lives under archive/ so should be ignored"
template/init.sh
EOF
  run "$(hook check_no_stale_template_refs.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/archive/template/script/docker/_lib.sh\"}}"
  assert_silent
}

@test "silent on .md file under .base/ (doc may discuss rename)" {
  cat > "${TMPDIR}/.base/README.md" <<'EOF'
The subtree dir was renamed from template/ to .base/ in v0.25.0.
See template/script/docker/_lib.sh for the old path.
EOF
  run "$(hook check_no_stale_template_refs.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/.base/README.md\"}}"
  assert_silent
}

@test "silent on non-shell file under .base/" {
  cat > "${TMPDIR}/.base/script/docker/notes.txt" <<'EOF'
template/init.sh is the old path
EOF
  run "$(hook check_no_stale_template_refs.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/.base/script/docker/notes.txt\"}}"
  assert_silent
}

@test "silent on missing file" {
  run "$(hook check_no_stale_template_refs.sh)" <<< "{\"tool_input\":{\"file_path\":\"${TMPDIR}/.base/script/docker/nonexistent.sh\"}}"
  assert_silent
}

@test "silent on empty tool_input" {
  run "$(hook check_no_stale_template_refs.sh)" <<< "{}"
  assert_silent
}
