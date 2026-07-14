#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  TMPDIR="$(mktemp -d)"
  REPO_DIR="${TMPDIR}/repo"
  mkdir -p "${REPO_DIR}/.claude/scripts/lib"

  # Copy the actual lint script the hook delegates to.
  cp "$(script check-log-helper-usage.sh)" "${REPO_DIR}/.claude/scripts/check-log-helper-usage.sh"
  chmod +x "${REPO_DIR}/.claude/scripts/check-log-helper-usage.sh"
}

teardown() {
  rm -rf "${TMPDIR}"
}

# run_hook <file-path> -- send PostToolUse JSON to the hook.
run_hook() {
  local fp="$1"
  run "$(hook remind_log_helper.sh)" <<< "{\"tool_input\":{\"file_path\":\"${fp}\"}}"
}

@test "silent on non-script file" {
  echo "some content" > "${REPO_DIR}/random.md"
  run_hook "${REPO_DIR}/random.md"
  assert_silent
}

@test "silent on .claude/scripts/lib/*.sh (lib is excluded)" {
  cat > "${REPO_DIR}/.claude/scripts/lib/foo.sh" <<'BASH'
#!/usr/bin/env bash
echo "internal lib helper"
BASH
  run_hook "${REPO_DIR}/.claude/scripts/lib/foo.sh"
  assert_silent
}

@test "silent when file does not exist" {
  run_hook "${REPO_DIR}/.claude/scripts/missing.sh"
  assert_silent
}

@test "silent on script that uses _log_* only" {
  cat > "${REPO_DIR}/.claude/scripts/clean.sh" <<'BASH'
#!/usr/bin/env bash
source ./lib/log.sh
main() {
  _log_info svc summary
}
main "$@"
BASH
  run_hook "${REPO_DIR}/.claude/scripts/clean.sh"
  assert_silent
}

@test "silent on script with file-wide log-allow:script marker" {
  cat > "${REPO_DIR}/.claude/scripts/allowed.sh" <<'BASH'
#!/usr/bin/env bash
# log-allow:script
main() {
  printf 'data product\n'
}
main "$@"
BASH
  run_hook "${REPO_DIR}/.claude/scripts/allowed.sh"
  assert_silent
}

@test "fires on bare printf outside usage()" {
  cat > "${REPO_DIR}/.claude/scripts/dirty.sh" <<'BASH'
#!/usr/bin/env bash
main() {
  printf 'hello\n'
}
main "$@"
BASH
  run_hook "${REPO_DIR}/.claude/scripts/dirty.sh"
  assert_message_contains "Bare printf"
  assert_message_contains "lib/log.sh adoption"
  assert_message_contains "log-allow:script"
}

@test "fires on bare echo outside usage()" {
  cat > "${REPO_DIR}/.claude/scripts/dirty.sh" <<'BASH'
#!/usr/bin/env bash
main() {
  echo "hi"
}
main "$@"
BASH
  run_hook "${REPO_DIR}/.claude/scripts/dirty.sh"
  assert_message_contains "Bare"
  assert_message_contains "echo"
}
