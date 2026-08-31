#!/usr/bin/env bats
#
# enforce_rm_outside_git_tree.sh -- the rm guard whose question is the
# RESOLVED TARGET, not the command text (refs #290).
#
# Every stanza here drives the hook and reads its verdict. That matters more
# than usual for this hook: the mechanism it replaces was a 480-entry list of
# literal `Bash(rm ...)` prefix matches that was BOTH incomplete (the next
# caller-chosen variable name always missed) and unsound (`rm -rf /tmp/../etc`
# starts with the allowed prefix `rm -rf /tmp/`). Both directions are proven
# below against real fixtures on a real filesystem, because the property is a
# pure function of a command string and a filesystem and there is nothing here
# that has to be asserted by comment.
#
# Fixture layout, built fresh per test under /tmp (which is inside no repo):
#
#   <base>/scratch          a directory outside every git working tree
#   <base>/scratch/afile    a FILE, so a path "through" it cannot resolve
#   <base>/repo             a git working tree
#   <base>/repo/dist        a directory inside it
#   <base>/repo/README.md   a tracked file
#   <base>/repo/.env        a GITIGNORED file (the open question, decided)

bats_require_minimum_version 1.5.0

load '../lib/test_helper'

setup() {
  RMG_BASE="$(mktemp -d /tmp/rmg-spec.XXXXXX)"
  SCRATCH="${RMG_BASE}/scratch"
  REPO="${RMG_BASE}/repo"
  mkdir -p "${SCRATCH}" "${REPO}"
  printf 'x\n' > "${SCRATCH}/afile"
  git init -q -b main "${REPO}"
  git -C "${REPO}" config user.email 't@t'
  git -C "${REPO}" config user.name 't'
  mkdir -p "${REPO}/dist"
  printf '# readme\n' > "${REPO}/README.md"
  printf '.env\n'     > "${REPO}/.gitignore"
  printf 'K=v\n'      > "${REPO}/.env"
  git -C "${REPO}" add -A >/dev/null
  git -C "${REPO}" commit -qm init >/dev/null
  export TMPDIR="${SCRATCH}"
  HOOK="$(hook enforce_rm_outside_git_tree.sh)"
}

teardown() {
  rm -rf "${RMG_BASE}"
}

# fire <command> [cwd] -- run the hook on <command>, as if issued from [cwd].
#
# --separate-stderr because the verdict is what the hook writes to STDOUT:
# that is the only stream Claude Code parses, and a hook that dies has its
# diagnostic on stderr. Merging the two would make a crash's error text look
# like a malformed verdict, which is precisely the difference the process-level
# stanzas below exist to measure.
fire() {
  local json
  json="$(jq -nc --arg c "$1" --arg d "${2:-}" \
    '{cwd: $d, tool_input: {command: $c}}')"
  run --separate-stderr "${HOOK}" <<< "${json}"
}

# assert_reason_contains <needle>
assert_reason_contains() {
  local got
  got="$(echo "${output}" | jq -r \
    '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
  if [[ "${got}" != *"$1"* ]]; then
    echo "expected reason to contain '$1', got: ${got}" >&2
    return 1
  fi
}

# --- the three spellings that walked past the 480 prefix rules -------------

@test "allows rm -rf \"\$TMPDIR/mut957\" -- the quote precedes the variable" {
  fire 'rm -rf "$TMPDIR/mut957"'
  assert_permission_decision "allow"
}

@test "allows a caller-named variable assigned in the same command" {
  fire "SCRATCH=${SCRATCH}; rm -rf \$SCRATCH/red955 \$SCRATCH/green955"
  assert_permission_decision "allow"
}

@test "allows a single-letter exported variable assigned in the same command" {
  fire "export T=${SCRATCH}; rm -rf \"\$T/a1\""
  assert_permission_decision "allow"
}

@test "allows a literal scratch path that does not exist yet" {
  fire "rm -rf ${SCRATCH}/base951mut.XXXX"
  assert_permission_decision "allow"
}

# --- the unsound direction: resolution, not prefix ------------------------

@test "denies /tmp/../<repo>/dist -- the case the prefix rules let through" {
  fire "rm -rf ${SCRATCH}/../repo/dist"
  assert_permission_decision "deny"
  assert_reason_contains "inside the git working tree"
}

@test "denies rm README.md issued from inside the repo" {
  fire 'rm README.md' "${REPO}"
  assert_permission_decision "deny"
}

@test "denies the second operand of a chain whose first operand is fine" {
  fire "rm -rf ${SCRATCH}/ok && rm -rf ${REPO}/dist"
  assert_permission_decision "deny"
  assert_reason_contains "${REPO}/dist"
}

@test "denies the repo root itself, which its own parent would not catch" {
  fire "rm -rf ${REPO}"
  assert_permission_decision "deny"
}

@test "denies a gitignored file inside the repo (decided, not incidental)" {
  fire "rm ${REPO}/.env"
  assert_permission_decision "deny"
}

@test "denies the filesystem root" {
  fire 'rm -rf /'
  assert_permission_decision "deny"
  assert_reason_contains "filesystem root"
}

# --- fail closed ----------------------------------------------------------

@test "denies an operand whose directory cannot be resolved" {
  fire "rm -rf ${SCRATCH}/afile/inner"
  assert_permission_decision "deny"
  assert_reason_contains "no resolvable directory"
}

@test "denies a relative operand when the invocation cwd does not resolve" {
  fire 'rm foo.txt' "${RMG_BASE}/gone"
  assert_permission_decision "deny"
  assert_reason_contains "does not resolve"
}

@test "denies an operand built from a variable nothing defines" {
  fire 'rm -rf $RMG_NO_SUCH_VARIABLE_290/x'
  assert_permission_decision "deny"
  assert_reason_contains "set neither in the command nor in the environment"
}

@test "denies a command it cannot parse (command substitution)" {
  fire 'rm -rf $(cat targets.txt)'
  assert_permission_decision "deny"
  assert_reason_contains "does not parse"
}

@test "denies a glob operand, whose matches are not known until the shell runs" {
  fire "rm -rf ${SCRATCH}/*"
  assert_permission_decision "deny"
}

@test "denies rm reached through xargs" {
  fire "find ${SCRATCH} -name x | xargs rm -rf"
  assert_permission_decision "deny"
  assert_reason_contains "does not model"
}

@test "denies rm reached through find -exec" {
  fire "find ${SCRATCH} -name x -exec rm {} \\;"
  assert_permission_decision "deny"
}

# --- bash -c --------------------------------------------------------------

@test "denies an in-repo target inside a bash -c payload" {
  fire "bash -c \"rm -rf ${REPO}/dist\""
  assert_permission_decision "deny"
}

@test "allows an out-of-repo target inside a bash -c payload" {
  fire "bash -c 'rm -rf ${SCRATCH}/x'"
  assert_permission_decision "allow"
}

# --- symlinks: rm removes the link, not what it points at -----------------

@test "denies a repo path reached through a symlinked parent" {
  ln -s "${REPO}" "${SCRATCH}/link"
  fire "rm -rf ${SCRATCH}/link/dist"
  assert_permission_decision "deny"
}

@test "allows deleting a symlink that points into a repo" {
  ln -s "${REPO}" "${SCRATCH}/link"
  fire "rm ${SCRATCH}/link"
  assert_permission_decision "allow"
}

# --- flags and separators -------------------------------------------------

@test "honours -- as end of options" {
  fire "rm -rf -- ${REPO}/dist"
  assert_permission_decision "deny"
}

@test "treats a name after -- as an operand, not a flag" {
  fire "rm -- ${SCRATCH}/-weird-name"
  assert_permission_decision "allow"
}

@test "treats a bare - as a filename, not a flag" {
  fire 'rm -' "${REPO}"
  assert_permission_decision "deny"
}

@test "does not read a redirection target as an rm operand" {
  fire "rm ${SCRATCH}/a > ${REPO}/log 2>&1"
  assert_permission_decision "allow"
}

@test "keeps a quoted operand containing spaces as one operand" {
  fire "rm -rf \"${SCRATCH}/a b\""
  assert_permission_decision "allow"
}

# --- silent: nothing here is an rm invocation -----------------------------

@test "silent on a command with no rm word at all" {
  fire 'ls -la /tmp'
  assert_silent
}

@test "silent on rmdir, which is a different command" {
  fire 'rmdir empty/'
  assert_silent
}

@test "silent on git rm, which is out of scope by decision" {
  fire 'git rm README.md' "${REPO}"
  assert_silent
}

@test "silent on an rm word that is quoted data, not an invocation" {
  fire "echo 'rm -rf ${REPO}'"
  assert_silent
}

@test "silent on an rm word inside a heredoc body" {
  fire "$(printf 'cat <<%s > %s/f\nrm -rf %s\n%s\n' \
    "'EOF'" "${SCRATCH}" "${REPO}" 'EOF')"
  assert_silent
}

@test "denies an unquoted loose rm word, the stated cost of failing closed" {
  fire 'echo rm'
  assert_permission_decision "deny"
}

@test "silent when the tool input carries no command" {
  run "${HOOK}" <<< '{"tool_input":{}}'
  assert_silent
}

# --- the process-level default --------------------------------------------
#
# A hook that emits nothing is read as "this guard had nothing to say", and
# the deletion proceeds. So "the guard crashed" and "the guard approved" are
# the same event to everything downstream, and the guard's default on a
# process it did not survive must be the same as its default on input it did
# not recognise: refuse. The stanzas below kill the hook three different ways
# and assert a deny still reaches stdout.
#
# They mutate a COPY: the claim is not "this particular line cannot fail", it
# is "whatever kills this hook, the deletion is still refused", and only a
# crash the code does not know about can prove that.

# crash_mutant <injected code> -- path to a copy of the hook with <injected
# code> spliced into the top of rmg_tokenize(), i.e. after the hook has read
# its input and before it can reach any verdict.
crash_mutant() {
  local mutant="${RMG_BASE}/crash-mutant.sh"
  sed "s|^rmg_tokenize() {\$|rmg_tokenize() { $1|" "${HOOK}" > "${mutant}"
  chmod +x "${mutant}"
  if cmp -s "${HOOK}" "${mutant}"; then
    echo "crash_mutant: injection anchor 'rmg_tokenize() {' not found" >&2
    return 1
  fi
  printf '%s\n' "${mutant}"
}

@test "denies when the guard dies on an unbound variable" {
  HOOK="$(crash_mutant ': "${RMG_DELIBERATE_CRASH_290}";')"
  fire "rm -rf ${SCRATCH}/x"
  assert_permission_decision "deny"
  assert_reason_contains "before it reached a verdict"
}

@test "denies when the guard exits mid-parse" {
  HOOK="$(crash_mutant 'exit 3;')"
  fire "rm -rf ${SCRATCH}/x"
  assert_permission_decision "deny"
  assert_reason_contains "before it reached a verdict"
}

@test "denies when the guard is terminated by a signal" {
  HOOK="$(crash_mutant 'kill -TERM $$;')"
  fire "rm -rf ${SCRATCH}/x"
  assert_permission_decision "deny"
  assert_reason_contains "before it reached a verdict"
}

@test "still says nothing when a command carries no rm at all" {
  fire 'ls -la /tmp'
  assert_silent
}

# --- special parameters ---------------------------------------------------
#
# The header says `$1` / `$@` / `$?` are not parsed and are therefore denied.
# "Denied" has to mean a verdict the guard reached, not a crash the trap
# above caught: a guard that dies on a whole class of input tells its author
# nothing about the class. So these stanzas assert the deny AND assert the
# reason names the parameter, which only the parser can do.

@test "denies every special parameter, and says which" {
  local p
  for p in '$1' '$@' '$*' '$?' '$$' '$#' '$!' '$-'; do
    fire "rm -rf ${p}/x"
    if ! assert_permission_decision "deny"; then
      echo "special parameter ${p} was not denied" >&2
      return 1
    fi
    if ! assert_reason_contains "special parameter"; then
      echo "... for special parameter ${p}" >&2
      return 1
    fi
  done
}

@test "denies a real in-tree operand that follows a special parameter" {
  fire "rm -rf \$1 ${REPO}/src"
  assert_permission_decision "deny"
}

@test "refuses a special parameter without dying on it" {
  fire 'rm -rf $1'
  assert_permission_decision "deny"
  if [[ -n "${stderr}" ]]; then
    echo "the guard wrote to stderr instead of deciding: ${stderr}" >&2
    return 1
  fi
}

# --- bash -c, spelled the way bash accepts it -----------------------------
#
# `-c` is not always the last character of the option bundle. Real bash runs
# the payload of `bash -cx '...'` exactly as it runs `bash -xc '...'`, and a
# guard that only recognises the second spelling looks covered while the
# first walks past it -- into the same fail-open the process-level stanzas
# above close, reached through the parser instead of through a crash.

@test "denies an in-repo target under bash -cx, where -c is not last" {
  fire "bash -cx 'rm -rf ${REPO}/src'"
  assert_permission_decision "deny"
}

@test "denies an in-repo target under bash -ce" {
  fire "bash -ce 'rm -rf ${REPO}/src'"
  assert_permission_decision "deny"
}

@test "denies an in-repo target under sh -cx" {
  fire "sh -cx 'rm -rf ${REPO}/src'"
  assert_permission_decision "deny"
}

@test "allows an out-of-repo target under bash -cx: the payload is read, not refused" {
  fire "bash -cx 'rm -rf ${SCRATCH}/x'"
  assert_permission_decision "allow"
}

@test "denies an option bundle it cannot place a payload in, and says so" {
  fire "bash -c'rm -rf ${REPO}/src'"
  assert_permission_decision "deny"
  assert_reason_contains "does not model"
}

@test "denies a shell option that takes an argument of its own" {
  fire "bash -o errexit -c 'rm -rf ${SCRATCH}/x'"
  assert_permission_decision "deny"
  assert_reason_contains "does not model"
}

@test "denies a long shell option that takes an argument of its own" {
  fire "bash --rcfile ${SCRATCH}/rc -c 'rm -rf ${REPO}/src'"
  assert_permission_decision "deny"
  assert_reason_contains "does not model"
}

@test "still reads the payload after a long option that takes none" {
  fire "bash --norc -c 'rm -rf ${REPO}/src'"
  assert_permission_decision "deny"
  assert_reason_contains "inside the git working tree"
}

# --- unquoted expansion: what the shell does with the value ---------------
#
# An unquoted `$X` is not one word. The shell splits its value on IFS and
# then expands globs in the pieces, so the operands rm receives are not
# knowable from the value read as a path. The guard used to append the value
# to the current word and resolve it as ONE path: a value holding two paths
# resolved to a single nonexistent one, which sits outside every repo, and
# the answer came back ALLOW while the shell deleted a tracked file.

@test "denies an unquoted expansion whose value would split into two paths" {
  fire "X=\"${SCRATCH}/junk ${REPO}/README.md\"; rm -rf \$X"
  assert_permission_decision "deny"
  assert_reason_contains "split"
}

@test "the shell really does delete the in-tree file that expansion hides" {
  printf 'j\n' > "${SCRATCH}/junk"
  bash -c "X=\"${SCRATCH}/junk ${REPO}/README.md\"; rm -rf \$X"
  if [[ -e "${REPO}/README.md" ]]; then
    echo "fixture is wrong: the second path survived, so the guard's ALLOW was not a miss" >&2
    return 1
  fi
}

@test "denies an unquoted expansion whose value would glob" {
  fire "X='${SCRATCH}/*'; rm -rf \$X"
  assert_permission_decision "deny"
  assert_reason_contains "glob"
}

@test "denies the braced spelling of the same unquoted expansion" {
  fire "X=\"${SCRATCH}/junk ${REPO}/README.md\"; rm -rf \${X}"
  assert_permission_decision "deny"
}

@test "denies an unquoted expansion of an environment variable that splits" {
  RMG_SPLIT_290="${SCRATCH}/junk ${REPO}/README.md" \
    run --separate-stderr "${HOOK}" <<< \
    "$(jq -nc --arg c 'rm -rf $RMG_SPLIT_290' --arg d "${SCRATCH}" \
      '{cwd: $d, tool_input: {command: $c}}')"
  assert_permission_decision "deny"
}

@test "allows the same value quoted, which really is one path" {
  fire "X=\"${SCRATCH}/a b\"; rm -rf \"\$X\""
  assert_permission_decision "allow"
}

@test "allows an unquoted expansion whose value is a single plain path" {
  fire "X=${SCRATCH}/one; rm -rf \$X"
  assert_permission_decision "allow"
}
