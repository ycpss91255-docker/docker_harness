#!/usr/bin/env bats
#
# auto_allow_rm_outside_git_tree.sh -- the hook that spares the human when
# it can resolve every rm target, and names the tree when it cannot (#290).
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
  HOOK="$(hook auto_allow_rm_outside_git_tree.sh)"
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

# assert_no_verdict -- assert the hook left NOTHING on stdout. Deliberately
# says nothing about the exit code: a hook that dies exits non-zero and
# Claude Code reports that as a hook error, which still leaves the tool call
# to the permission rules. The only outcome that would be worse than silence
# is a verdict, so a verdict is the only thing asserted against.
assert_no_verdict() {
  if [[ -n "${output}" ]]; then
    echo "expected no verdict on stdout, got: ${output}" >&2
    return 1
  fi
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
  assert_permission_decision "ask"
  assert_reason_contains "inside the git working tree"
}

@test "denies rm README.md issued from inside the repo" {
  fire 'rm README.md' "${REPO}"
  assert_permission_decision "ask"
}

@test "denies the second operand of a chain whose first operand is fine" {
  fire "rm -rf ${SCRATCH}/ok && rm -rf ${REPO}/dist"
  assert_permission_decision "ask"
  assert_reason_contains "${REPO}/dist"
}

@test "denies the repo root itself, which its own parent would not catch" {
  fire "rm -rf ${REPO}"
  assert_permission_decision "ask"
}

@test "denies a gitignored file inside the repo (decided, not incidental)" {
  fire "rm ${REPO}/.env"
  assert_permission_decision "ask"
}

@test "denies the filesystem root" {
  fire 'rm -rf /'
  assert_permission_decision "ask"
  assert_reason_contains "filesystem root"
}

# --- fail closed ----------------------------------------------------------

@test "denies an operand whose directory cannot be resolved" {
  fire "rm -rf ${SCRATCH}/afile/inner"
  assert_permission_decision "ask"
  assert_reason_contains "no resolvable directory"
}

@test "denies a relative operand when the invocation cwd does not resolve" {
  fire 'rm foo.txt' "${RMG_BASE}/gone"
  assert_permission_decision "ask"
  assert_reason_contains "does not resolve"
}

@test "denies an operand built from a variable nothing defines" {
  fire 'rm -rf $RMG_NO_SUCH_VARIABLE_290/x'
  assert_permission_decision "ask"
  assert_reason_contains "set neither in the command nor in the environment"
}

@test "denies a command it cannot parse (command substitution)" {
  fire 'rm -rf $(cat targets.txt)'
  assert_permission_decision "ask"
  assert_reason_contains "does not parse"
}

@test "denies a glob operand, whose matches are not known until the shell runs" {
  fire "rm -rf ${SCRATCH}/*"
  assert_permission_decision "ask"
}

@test "denies rm reached through xargs" {
  fire "find ${SCRATCH} -name x | xargs rm -rf"
  assert_permission_decision "ask"
  assert_reason_contains "does not model"
}

@test "denies rm reached through find -exec" {
  fire "find ${SCRATCH} -name x -exec rm {} \\;"
  assert_permission_decision "ask"
}

# --- bash -c --------------------------------------------------------------

@test "denies an in-repo target inside a bash -c payload" {
  fire "bash -c \"rm -rf ${REPO}/dist\""
  assert_permission_decision "ask"
}

@test "allows an out-of-repo target inside a bash -c payload" {
  fire "bash -c 'rm -rf ${SCRATCH}/x'"
  assert_permission_decision "allow"
}

# --- symlinks: rm removes the link, not what it points at -----------------

@test "denies a repo path reached through a symlinked parent" {
  ln -s "${REPO}" "${SCRATCH}/link"
  fire "rm -rf ${SCRATCH}/link/dist"
  assert_permission_decision "ask"
}

@test "allows deleting a symlink that points into a repo" {
  ln -s "${REPO}" "${SCRATCH}/link"
  fire "rm ${SCRATCH}/link"
  assert_permission_decision "allow"
}

# --- flags and separators -------------------------------------------------

@test "honours -- as end of options" {
  fire "rm -rf -- ${REPO}/dist"
  assert_permission_decision "ask"
}

@test "treats a name after -- as an operand, not a flag" {
  fire "rm -- ${SCRATCH}/-weird-name"
  assert_permission_decision "allow"
}

@test "treats a bare - as a filename, not a flag" {
  fire 'rm -' "${REPO}"
  assert_permission_decision "ask"
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

@test "git rm now costs a prompt, because git can also carry a shell" {
  fire 'git rm README.md' "${REPO}"
  assert_permission_decision "ask"
}

@test "denies a quoted rm inside a command it does not model" {
  fire "echo 'rm -rf ${REPO}'"
  assert_permission_decision "ask"
}

@test "an rm word inside a heredoc body asks, because a heredoc can feed a shell" {
  fire "$(printf 'cat <<%s > %s/f\nrm -rf %s\n%s\n' \
    "'EOF'" "${SCRATCH}" "${REPO}" 'EOF')"
  assert_permission_decision "ask"
}

@test "denies an unquoted loose rm word, the stated cost of failing closed" {
  fire 'echo rm'
  assert_permission_decision "ask"
}

@test "silent when the tool input carries no command" {
  run "${HOOK}" <<< '{"tool_input":{}}'
  assert_silent
}

# --- the process-level default --------------------------------------------
#
# There is no trap and no default verdict. `permissions.ask: Bash(rm:*)` is
# the guard, so a hook that emits nothing has handed the deletion to a human
# -- which makes "the guard crashed" and "the guard had no opinion" the same
# SAFE event instead of the same unsafe one. The stanzas below kill the hook
# three different ways and assert that nothing reaches stdout, because a
# half-verdict or a stray `allow` is the only thing a dying hook could do
# that would be worse than silence.
#
# They mutate a COPY: the claim is not "this particular line cannot fail", it
# is "whatever kills this hook, the deletion still reaches the ask rule".

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
    if ! assert_permission_decision "ask"; then
      echo "special parameter ${p} was not asked about" >&2
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
  assert_permission_decision "ask"
}

@test "refuses a special parameter without dying on it" {
  fire 'rm -rf $1'
  assert_permission_decision "ask"
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
  assert_permission_decision "ask"
}

@test "denies an in-repo target under bash -ce" {
  fire "bash -ce 'rm -rf ${REPO}/src'"
  assert_permission_decision "ask"
}

@test "denies an in-repo target under sh -cx" {
  fire "sh -cx 'rm -rf ${REPO}/src'"
  assert_permission_decision "ask"
}

@test "allows an out-of-repo target under bash -cx: the payload is read, not refused" {
  fire "bash -cx 'rm -rf ${SCRATCH}/x'"
  assert_permission_decision "allow"
}

@test "denies an option bundle it cannot place a payload in, and says so" {
  fire "bash -c'rm -rf ${REPO}/src'"
  assert_permission_decision "ask"
  assert_reason_contains "does not model"
}

@test "denies a shell option that takes an argument of its own" {
  fire "bash -o errexit -c 'rm -rf ${SCRATCH}/x'"
  assert_permission_decision "ask"
  assert_reason_contains "does not model"
}

@test "denies a long shell option that takes an argument of its own" {
  fire "bash --rcfile ${SCRATCH}/rc -c 'rm -rf ${REPO}/src'"
  assert_permission_decision "ask"
  assert_reason_contains "does not model"
}

@test "still reads the payload after a long option that takes none" {
  fire "bash --norc -c 'rm -rf ${REPO}/src'"
  assert_permission_decision "ask"
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
  assert_permission_decision "ask"
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
  assert_permission_decision "ask"
  assert_reason_contains "glob"
}

@test "denies the braced spelling of the same unquoted expansion" {
  fire "X=\"${SCRATCH}/junk ${REPO}/README.md\"; rm -rf \${X}"
  assert_permission_decision "ask"
}

@test "denies an unquoted expansion of an environment variable that splits" {
  RMG_SPLIT_290="${SCRATCH}/junk ${REPO}/README.md" \
    run --separate-stderr "${HOOK}" <<< \
    "$(jq -nc --arg c 'rm -rf $RMG_SPLIT_290' --arg d "${SCRATCH}" \
      '{cwd: $d, tool_input: {command: $c}}')"
  assert_permission_decision "ask"
}

@test "allows the same value quoted, which really is one path" {
  fire "X=\"${SCRATCH}/a b\"; rm -rf \"\$X\""
  assert_permission_decision "allow"
}

@test "allows an unquoted expansion whose value is a single plain path" {
  fire "X=${SCRATCH}/one; rm -rf \$X"
  assert_permission_decision "allow"
}

# --- containment: a target that is not a tree but holds one ---------------
#
# Asking only "is the target inside a working tree?" denies `rm README.md`
# and allows `rm -rf <the directory every repo lives in>`, because that
# directory is not itself a tree. The trivial deletion is refused and the
# maximally destructive one is waved through. The question the guard asks is
# therefore about any part of any tree: inside one, or holding one.

@test "denies a directory that is not a working tree but contains one" {
  fire "rm -rf ${RMG_BASE}"
  assert_permission_decision "ask"
  assert_reason_contains "contains the git working tree"
}

@test "denies a directory that contains a working tree several levels down" {
  mkdir -p "${SCRATCH}/holder/a/b/c"
  git init -q -b main "${SCRATCH}/holder/a/b/c/clone"
  fire "rm -rf ${SCRATCH}/holder"
  assert_permission_decision "ask"
  assert_reason_contains "contains the git working tree"
}

@test "allows a directory tree with no working tree anywhere under it" {
  mkdir -p "${SCRATCH}/holder/a/b/c"
  printf 'x\n' > "${SCRATCH}/holder/a/b/c/file"
  fire "rm -rf ${SCRATCH}/holder"
  assert_permission_decision "allow"
}

@test "denies a target it could not finish searching" {
  mkdir -p "${SCRATCH}/wide/a" "${SCRATCH}/wide/b" "${SCRATCH}/wide/c"
  RMG_SCAN_MAX_DIRS=1 run --separate-stderr "${HOOK}" <<< \
    "$(jq -nc --arg c "rm -rf ${SCRATCH}/wide" --arg d "${SCRATCH}" \
      '{cwd: $d, tool_input: {command: $c}}')"
  assert_permission_decision "ask"
  assert_reason_contains "budget"
}

@test "allows a directory small enough to search inside the budget" {
  mkdir -p "${SCRATCH}/narrow"
  RMG_SCAN_MAX_DIRS=1 run --separate-stderr "${HOOK}" <<< \
    "$(jq -nc --arg c "rm -rf ${SCRATCH}/narrow" --arg d "${SCRATCH}" \
      '{cwd: $d, tool_input: {command: $c}}')"
  assert_permission_decision "allow"
}

@test "does not search past a symlink, which rm would not follow either" {
  mkdir -p "${SCRATCH}/holder"
  ln -s "${REPO}" "${SCRATCH}/holder/link"
  fire "rm -rf ${SCRATCH}/holder"
  assert_permission_decision "allow"
}

@test "still allows a file whose parent holds a working tree" {
  printf 'x\n' > "${RMG_BASE}/loose"
  fire "rm -rf ${RMG_BASE}/loose"
  assert_permission_decision "allow"
}

# --- the message says what was resolved -----------------------------------
#
# The deny exists to be read by whoever typed the command, and the one thing
# it has that they do not is the RESOLVED target. Printing the spelling back
# at them ("resolves to /tmp/../repo/dist") spends the sentence on the half
# they already had, and naming the probed directory as the working tree
# ("the working tree at .../repo/dist") tells them a tree is somewhere it is
# not.

@test "names the resolved target rather than the spelling" {
  fire "rm -rf ${SCRATCH}/../repo/dist"
  assert_permission_decision "ask"
  assert_reason_contains "resolves to ${REPO}/dist"
  # The reason quotes the operand as typed first -- that is how the reader
  # finds which operand it is about -- so the check is on what follows
  # "resolves to": that half must be the resolution, not the spelling again.
  local got
  got="$(echo "${output}" | jq -r \
    '.hookSpecificOutput.permissionDecisionReason // empty')"
  if [[ "${got#*resolves to }" == *"${SCRATCH}/../"* ]]; then
    echo "the reason resolved the spelling to itself: ${got}" >&2
    return 1
  fi
}

@test "names the working tree by its root, not by the directory it probed" {
  fire "rm -rf ${REPO}/dist"
  assert_permission_decision "ask"
  assert_reason_contains "working tree at ${REPO}."
}

@test "denies a path that resolves to the filesystem root by another spelling" {
  fire 'rm -rf /tmp/..'
  assert_permission_decision "ask"
  assert_reason_contains "filesystem root"
}

# --- a wrapper carrying its rm inside a quoted word -----------------------
#
# The rule for a command this guard does not model used to be "an UNQUOTED
# word equal to rm denies", which reads as a rule about invocations and is
# really a rule about quoting: `xargs rm -rf` denied, and
# `xargs -I{} sh -c 'rm -rf <repo>'` -- the same deletion, one quote further
# in -- returned silently, and silence is consent to everything downstream.
# The guard cannot tell an executing word from an inert one without knowing
# each wrapper's semantics, which is exactly the enumeration this issue
# exists to stop writing. So the rule is now about the token: a command this
# guard does not model that mentions `rm` at all denies, quoted or not.

@test "denies rm carried in a quoted payload through xargs" {
  fire "xargs -I{} sh -c 'rm -rf ${REPO}/src'"
  assert_permission_decision "ask"
}

@test "denies rm carried in a quoted payload through env" {
  fire "env bash -c 'rm -rf ${REPO}/src'"
  assert_permission_decision "ask"
}

@test "denies rm carried in a quoted payload through timeout" {
  fire "timeout 5 bash -c 'rm -rf ${REPO}/src'"
  assert_permission_decision "ask"
}

@test "denies a quoted rm even when its target is outside every tree" {
  fire "env bash -c 'rm -rf ${SCRATCH}/x'"
  assert_permission_decision "ask"
  assert_reason_contains "does not model"
}

@test "stays silent on --rm, which is not an rm token" {
  fire 'docker run --rm alpine true'
  assert_silent
}

@test "stays silent on a word that merely contains the letters rm" {
  fire "confirm-rm-helper ${REPO}/x"
  assert_silent
}

@test "a heredoc body with no rm token in it stays silent" {
  fire "$(printf 'cat <<%s > %s/f\nhello\n%s\n' \
    "'EOF'" "${SCRATCH}" 'EOF')"
  assert_silent
}

@test "git asks when it mentions rm, and stays silent when it does not" {
  fire "git commit -m 'drop the rm guard' " "${REPO}"
  assert_permission_decision "ask"
  fire "git commit -m 'drop the guard' " "${REPO}"
  assert_silent
}

# --- the search budgets are the operator's to lower, not to break ---------

@test "falls back to the default budget when the environment sets nonsense" {
  mkdir -p "${SCRATCH}/holder/a/b"
  RMG_SCAN_MAX_DIRS=not-a-number run --separate-stderr "${HOOK}" <<< \
    "$(jq -nc --arg c "rm -rf ${SCRATCH}/holder" --arg d "${SCRATCH}" \
      '{cwd: $d, tool_input: {command: $c}}')"
  assert_permission_decision "allow"
}

# --- WHERE THE GUARD ACTUALLY IS (refs #290, round 4) ---------------------
#
# Three review rounds proved that no parser over a command STRING can decide
# what a shell will delete: a heredoc fed to a shell, a here-string fed to a
# shell, `bash -c --`, `builtin cd` and `r"m"` each walked past a guard that
# had just been widened for the previous five. Bash's shapes are not finite,
# so the parser cannot be the guard.
#
# What can: `permissions.ask: Bash(rm:*)`, which is the human this property
# has always been asking for. Once that rule is back, this hook's SILENCE
# means "a human sees it" instead of "the deletion proceeds", and every way
# the hook can fail -- an unparsed construct, a missing jq, a crash, a
# timeout -- lands on the same safe default without a branch of its own.
#
# The stanzas below pin that inversion. They are the reason the hook may
# emit exactly two things and never a third.

@test "settings.json asks a human for every rm, which is what silence means" {
  run jq -r '.permissions.ask[]?' "${PROJECT_ROOT}/.claude/settings.json"
  assert_success
  assert_line "Bash(rm:*)"
}

@test "an in-tree target is handed to a human, not refused outright" {
  fire "rm -rf ${REPO}/dist"
  assert_permission_decision "ask"
}

@test "the hook never emits deny, whatever it is asked" {
  local c
  for c in "rm -rf ${REPO}/dist" \
           "rm -rf \$1" \
           "rm -rf ${SCRATCH}/*" \
           "xargs rm -rf ${SCRATCH}/x" \
           "rm -rf \$(echo x)"; do
    fire "${c}"
    if [[ "${output}" == *'"deny"'* ]]; then
      echo "hook denied '${c}'; deny is the permission system's to give, not this hook's" >&2
      return 1
    fi
  done
}

@test "a crash leaves no verdict at all, so the ask rule decides" {
  HOOK="$(crash_mutant ': "${RMG_DELIBERATE_CRASH_290}";')"
  fire "rm -rf ${SCRATCH}/x"
  assert_no_verdict
}

@test "an exit mid-parse leaves no verdict at all" {
  HOOK="$(crash_mutant 'exit 3;')"
  fire "rm -rf ${SCRATCH}/x"
  assert_no_verdict
}

@test "a signal leaves no verdict at all" {
  HOOK="$(crash_mutant 'kill -TERM $$;')"
  fire "rm -rf ${SCRATCH}/x"
  assert_no_verdict
}

@test "a missing jq cannot turn the hook into an allow" {
  local stub="${RMG_BASE}/nojq"
  mkdir -p "${stub}"
  printf '#!/bin/sh\nexit 127\n' > "${stub}/jq"
  chmod +x "${stub}/jq"
  local json
  json="$(jq -nc --arg c "rm -rf ${SCRATCH}/x" --arg d /tmp \
    '{cwd: $d, tool_input: {command: $c}}')"
  PATH="${stub}:${PATH}" run --separate-stderr "${HOOK}" <<< "${json}"
  if [[ "${output}" == *'"allow"'* ]]; then
    echo "hook allowed a deletion while jq was unavailable: ${output}" >&2
    return 1
  fi
}

# --- the five bypasses, dead by construction ------------------------------
#
# Round 3 proved each of these by deleting a tracked file out of a real git
# working tree, and each was one shell shape further out than the shape the
# previous round had just modelled. They are not fixed here by five more
# branches. They are fixed by three rules that cannot be spelled around:
#
#   1. text the lexer discards as DATA is still text a shell may execute, so
#      an `rm` token in a heredoc body or a here-string word makes the whole
#      command un-allowable;
#   2. a word this guard cannot PLACE is never analysed as if it could be --
#      `bash -c --` says so instead of reading the `--`;
#   3. a simple command this guard does not model may have moved the shell,
#      so it blanks the tracked cwd and every later relative operand is
#      unknown.
#
# And the gate in front of them reads quoting as the shell does, so a command
# word spelled `r"m"` reaches the lexer instead of never waking the hook.

@test "an rm in a heredoc body is not data when the reader is a shell" {
  fire "$(printf 'rm -rf %s/a; bash <<EOF\nrm -rf %s/src\nEOF\n' \
    "${SCRATCH}" "${REPO}")"
  assert_permission_decision "ask"
  assert_reason_contains "heredoc body"
}

@test "an rm in a here-string is not data when the reader is a shell" {
  fire "sh <<< 'rm -rf ${REPO}/src'"
  assert_permission_decision "ask"
  assert_reason_contains "here-string"
}

@test "bash -c -- runs the word after the dash-dash, which this guard will not guess" {
  fire "bash -c -- 'rm -rf ${REPO}/src'"
  assert_permission_decision "ask"
  assert_reason_contains "does not model"
}

@test "builtin cd may have moved the shell, so a later relative operand is unknown" {
  fire "builtin cd ${REPO} && rm -rf src" /tmp
  assert_permission_decision "ask"
  assert_reason_contains "may have moved the shell"
}

@test "command cd is caught by the same rule, without naming it" {
  fire "command cd ${REPO} && rm -rf src" /tmp
  assert_permission_decision "ask"
  assert_reason_contains "may have moved the shell"
}

@test "any unmodelled command between a cd and an rm costs the tracked cwd" {
  fire "cd ${REPO} && ls && rm -rf dist" /tmp
  assert_permission_decision "ask"
  assert_reason_contains "may have moved the shell"
}

@test "a cd straight to an rm still resolves, so the rule is not a blanket" {
  fire "cd ${SCRATCH} && rm -rf junk" /tmp
  assert_permission_decision "allow"
}

@test "a command word spelled r\"m\" is still an rm" {
  fire "r\"m\" -rf ${REPO}/src"
  assert_permission_decision "ask"
  assert_reason_contains "inside the git working tree"
}

@test "a command word spelled r'm' is still an rm" {
  fire "r'm' -rf ${REPO}/src"
  assert_permission_decision "ask"
  assert_reason_contains "inside the git working tree"
}

@test "a command word split by a backslash is still an rm" {
  fire "r\\m -rf ${REPO}/src"
  assert_permission_decision "ask"
  assert_reason_contains "inside the git working tree"
}

@test "an absolute path to rm is read as rm, not as an unknown command" {
  fire "/bin/rm -rf ${REPO}/src"
  assert_permission_decision "ask"
  assert_reason_contains "inside the git working tree"
}

# --- an assignment PREFIX is not this command's own variable ---------------

@test "an assignment prefix does not feed the expansions of its own command" {
  fire "X=${SCRATCH} rm -rf \$X/y"
  assert_permission_decision "ask"
  assert_reason_contains "set neither in the command nor in the environment"
}

@test "a standalone assignment before the rm still feeds it" {
  fire "X=${SCRATCH}; rm -rf \$X/y"
  assert_permission_decision "allow"
}

@test "an exported standalone assignment still feeds it" {
  fire "export X=${SCRATCH}; rm -rf \"\$X/y\""
  assert_permission_decision "allow"
}

# --- git carries shells too ------------------------------------------------
#
# `git` used to be skipped whole, on the grounds that `git rm` stages a
# deletion git can restore. That reasoning covers subcommands that delete
# THROUGH git and not subcommands that run a shell, and the second kind was
# invisible. The cost of dropping the special case is a prompt on `git rm`
# and on a git command that merely says `rm`; the benefit is that the ones
# below are seen at all.

@test "git submodule foreach carrying an rm reaches a human" {
  fire "git submodule foreach 'rm -rf ${REPO}/src'"
  assert_permission_decision "ask"
}

@test "git bisect run carrying an rm reaches a human" {
  fire "git bisect run rm -rf ${REPO}/src"
  assert_permission_decision "ask"
}

@test "git rebase -x carrying an rm reaches a human" {
  fire "git rebase -x 'rm -rf ${REPO}/src' main"
  assert_permission_decision "ask"
}

# --- the containment budget bounds the INVOCATION -------------------------
#
# A per-operand budget is not a bound: sixty directory operands each paying a
# full one outlive the 10s hook timeout, and a hook killed for running long
# emits nothing at all. These two stanzas differ only in operand count, so
# the budget they share is the thing under test.

@test "one operand inside the shared budget is answered and allowed" {
  local a="${SCRATCH}/many-a" i
  mkdir -p "${a}"
  for i in 1 2 3 4; do mkdir -p "${a}/d${i}"; done
  export RMG_SCAN_MAX_DIRS=6
  fire "rm -rf ${a}"
  unset RMG_SCAN_MAX_DIRS
  assert_permission_decision "allow"
}

@test "two operands that each fit the budget do not both fit it" {
  local a="${SCRATCH}/many-a" b="${SCRATCH}/many-b" i
  mkdir -p "${a}" "${b}"
  for i in 1 2 3 4; do mkdir -p "${a}/d${i}" "${b}/d${i}"; done
  export RMG_SCAN_MAX_DIRS=6
  fire "rm -rf ${a} ${b}"
  unset RMG_SCAN_MAX_DIRS
  assert_permission_decision "ask"
  assert_reason_contains "could not finish searching"
}

# --- two ways a resolved operand is still not the path bash deletes -------
#
# Found by driving the hook against real fixtures rather than by reading it.
# Both produced an affirmative ALLOW while bash deleted a tracked file, which
# is the one outcome this hook must not be able to reach -- everything else
# it gets wrong costs a prompt.

@test "ANSI-C quoting is a quoting form, not a literal dollar" {
  # `$'...'` is one word to bash and expands escapes inside it. The lexer
  # used to add a literal `$` and carry on, so the operand became the
  # relative path `$/tmp/...`, which resolved under the invocation cwd,
  # sat outside every tree, and was ALLOWED -- while bash deleted the
  # absolute in-tree path the quoting really names.
  fire "rm -rf \$'${REPO}/src'"
  assert_permission_decision "ask"
  assert_reason_contains "does not model"
}

@test "the locale-translation spelling is refused the same way" {
  fire "rm -rf \$\"${REPO}/src\""
  assert_permission_decision "ask"
  assert_reason_contains "does not model"
}

@test "a command that redefines IFS is not one whose word splitting is known" {
  # `IFS=/; X=/a/b; rm -rf $X` makes bash split the unquoted expansion into
  # the RELATIVE words `a` and `b`, deleting them in the cwd -- while the
  # hook read the value as one absolute path outside every tree and allowed
  # it. Splitting is the guard's own assumption, so a command that changes
  # it is a command it cannot answer for.
  fire "IFS=/; X=${SCRATCH}/y; rm -rf \$X" "${REPO}"
  assert_permission_decision "ask"
  assert_reason_contains "IFS"
}

@test "an IFS assignment inside a bash -c payload counts too" {
  fire "bash -c 'IFS=/; X=${SCRATCH}/y; rm -rf \$X'" "${REPO}"
  assert_permission_decision "ask"
  assert_reason_contains "IFS"
}

@test "the same command without the IFS assignment is still allowed" {
  fire "X=${SCRATCH}/y; rm -rf \$X" "${REPO}"
  assert_permission_decision "allow"
}
