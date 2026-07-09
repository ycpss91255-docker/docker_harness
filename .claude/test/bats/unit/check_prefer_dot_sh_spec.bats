#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  REPO="$(mktemp -d)"
  # Root justfile defining the container-ops recipes (build / run /
  # exec / stop), both bare (`stop:`) and parameterised (`build *args:`)
  # recipe forms so the recipe-existence grep is exercised.
  printf 'build *args:\n\t:\nrun *args:\n\t:\nexec *args:\n\t:\nstop:\n\t:\n' > "${REPO}/justfile"
  # A repo whose justfile lacks a `build` recipe (only `run`).
  REPO_NO_BUILD="$(mktemp -d)"
  printf 'run *args:\n\t:\n' > "${REPO_NO_BUILD}/justfile"
  # A repo with no justfile at all.
  REPO_BARE="$(mktemp -d)"
}

teardown() {
  rm -rf "${REPO}" "${REPO_NO_BUILD}" "${REPO_BARE}"
}

@test "deny docker build when justfile has build recipe" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker build -t foo .\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
  assert_message_contains "just build"
}

@test "deny docker run when justfile has run recipe" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker run --rm foo\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
  assert_message_contains "just run"
}

@test "deny docker exec when justfile has exec recipe" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker exec -it foo bash\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
  assert_message_contains "just exec"
}

@test "deny docker stop when justfile has stop recipe" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker stop foo\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
  assert_message_contains "just stop"
}

@test "deny docker compose up → just run" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker compose up -d\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
  assert_message_contains "just run"
}

@test "deny docker compose down → just stop" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker compose down\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
  assert_message_contains "just stop"
}

@test "deny docker compose build → just build" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker compose build\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
  assert_message_contains "just build"
}

@test "deny docker compose exec → just exec" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker compose exec foo bash\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
  assert_message_contains "just exec"
}

@test "deny docker compose run → just run" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker compose run foo\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
  assert_message_contains "just run"
}

@test "ask when docker build but no justfile" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker build -t foo .\"},\"cwd\":\"${REPO_BARE}\"}"
  assert_permission_decision "ask"
}

@test "ask when justfile present but no build recipe" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker build -t foo .\"},\"cwd\":\"${REPO_NO_BUILD}\"}"
  assert_permission_decision "ask"
}

@test "ask when docker compose up but no justfile" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker compose up\"},\"cwd\":\"${REPO_BARE}\"}"
  assert_permission_decision "ask"
}

@test "silent on read-only docker subcommand (ps)" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker ps -a\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent on read-only docker subcommand (images)" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker images\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent on docker pull (download is harmless)" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker pull alpine\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent on docker rm (already in permissions.ask)" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"docker rm -f foo\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent on non-docker command" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"git status\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "silent on make (subprocess docker is not visible to Claude)" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"make -f Makefile.ci test\"},\"cwd\":\"${REPO}\"}"
  assert_silent
}

@test "strips single env-prefix and matches docker build" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"BUILDKIT_PROGRESS=plain docker build -t foo .\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
  assert_message_contains "just build"
}

@test "strips multiple env-prefixes and matches docker build" {
  run "$(hook check_prefer_dot_sh.sh)" \
    <<< "{\"tool_input\":{\"command\":\"DOCKER_BUILDKIT=1 BUILDKIT_PROGRESS=plain docker build .\"},\"cwd\":\"${REPO}\"}"
  assert_permission_decision "deny"
}
