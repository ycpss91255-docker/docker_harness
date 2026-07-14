#!/usr/bin/env bats

load '../lib/test_helper'

setup() {
  GH_STUB_DIR="$(mktemp -d)"
  export PATH="${GH_STUB_DIR}:${PATH}"
}

teardown() {
  rm -rf "${GH_STUB_DIR}"
}

stub_gh() {
  local json="$1"
  printf '#!/usr/bin/env bash\nprintf %%s %q\n' "${json}" > "${GH_STUB_DIR}/gh"
  chmod +x "${GH_STUB_DIR}/gh"
}

stub_gh_seq() {
  local i=0
  local json
  for json in "$@"; do
    i=$((i + 1))
    printf '%s' "${json}" > "${GH_STUB_DIR}/resp_${i}.json"
  done
  local last="${i}"
  cat > "${GH_STUB_DIR}/gh" <<STUB_EOF
#!/usr/bin/env bash
cf="${GH_STUB_DIR}/call_count"
[[ -f "\${cf}" ]] || echo 0 > "\${cf}"
n=\$(<"\${cf}")
n=\$((n + 1))
echo "\${n}" > "\${cf}"
last=${last}
(( n > last )) && n=\${last}
cat "${GH_STUB_DIR}/resp_\${n}.json"
STUB_EOF
  chmod +x "${GH_STUB_DIR}/gh"
}

@test "--help prints usage and exits 0" {
  run "$(script wait-release.sh)" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--tag-pattern"
}

@test "missing --repo exits 2" {
  run "$(script wait-release.sh)" --tag-pattern '^v0\.'
  assert_failure 2
  assert_output --partial "--repo"
}

@test "missing --tag-pattern exits 2" {
  run "$(script wait-release.sh)" --repo a/b
  assert_failure 2
  assert_output --partial "--tag-pattern"
}

@test "unknown flag exits 2" {
  run "$(script wait-release.sh)" --bogus
  assert_failure 2
  assert_output --partial '"body":"unrecognised_arg"'
}

@test "empty release list keeps polling and hits max-iterations" {
  stub_gh '[]'
  run "$(script wait-release.sh)" --repo a/b --tag-pattern '^v0\.32\.' \
    --interval 0 --max-iterations 2
  assert_failure 124
}

@test "stable tag matching pattern exits 0 with classification" {
  stub_gh '[{"tagName":"v0.32.0"}]'
  run "$(script wait-release.sh)" --repo a/b --tag-pattern '^v0\.32\.' \
    --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "release: v0.32.0 (stable)"
}

@test "rc tag matching loose pattern emits rc snapshot then keeps polling" {
  stub_gh '[{"tagName":"v0.32.0-rc1"}]'
  run "$(script wait-release.sh)" --repo a/b --tag-pattern '^v0\.32\.' \
    --interval 0 --max-iterations 2
  assert_failure 124
  assert_output --partial "release: v0.32.0-rc1 (rc)"
}

@test "strict stable pattern excludes rc tag" {
  stub_gh '[{"tagName":"v0.32.0-rc1"}]'
  run "$(script wait-release.sh)" --repo a/b --tag-pattern '^v0\.32\.[0-9]+$' \
    --interval 0 --max-iterations 2
  assert_failure 124
  refute_output --partial "v0.32.0-rc1"
}

@test "stable preferred when both stable and older rc in list" {
  stub_gh '[{"tagName":"v0.32.0"},{"tagName":"v0.32.0-rc1"}]'
  run "$(script wait-release.sh)" --repo a/b --tag-pattern '^v0\.32\.' \
    --interval 0 --max-iterations 3
  assert_success
  assert_output --partial "release: v0.32.0 (stable)"
}

@test "--on-stable message printed after stable" {
  stub_gh '[{"tagName":"v0.32.0"}]'
  run "$(script wait-release.sh)" --repo a/b --tag-pattern '^v0\.32\.' \
    --interval 0 --max-iterations 3 --on-stable "now safe to adopt"
  assert_success
  assert_output --partial "now safe to adopt"
}

@test "--on-rc message printed for rc tag" {
  stub_gh '[{"tagName":"v0.32.0-rc1"}]'
  run "$(script wait-release.sh)" --repo a/b --tag-pattern '^v0\.32\.' \
    --interval 0 --max-iterations 2 --on-rc "rc cut, waiting for stable"
  assert_failure 124
  assert_output --partial "rc cut, waiting for stable"
}

@test "rc dedup across iterations emits once" {
  stub_gh '[{"tagName":"v0.32.0-rc1"}]'
  run "$(script wait-release.sh)" --repo a/b --tag-pattern '^v0\.32\.' \
    --interval 0 --max-iterations 4
  assert_failure 124
  local count
  count=$(printf '%s\n' "${output}" | grep -c 'release: v0.32.0-rc1')
  [ "${count}" -eq 1 ]
}

@test "non-matching tags are ignored" {
  stub_gh '[{"tagName":"v0.31.0"},{"tagName":"v0.30.5"}]'
  run "$(script wait-release.sh)" --repo a/b --tag-pattern '^v0\.32\.' \
    --interval 0 --max-iterations 2
  assert_failure 124
  refute_output --partial "release:"
}
