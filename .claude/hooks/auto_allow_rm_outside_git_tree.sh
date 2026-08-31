#!/usr/bin/env bash
# auto_allow_rm_outside_git_tree.sh -- Claude Code PreToolUse hook (Bash).
#
# READ THIS FIRST: THIS HOOK IS NOT THE GUARD.
#
# The guard is one line in .claude/settings.json:
#
#     "permissions": { "ask": [ ... "Bash(rm:*)" ... ] }
#
# That line is what stands between an `rm` and the filesystem, and it is a
# human. This file only decides when the human can be spared: it emits
#
#     allow   -- it resolved every target of every rm in the command and
#                every one of them is outside every git working tree;
#     ask     -- it reached a definite reason the human is needed, and says
#                which target and which tree;
#     nothing -- anything else.
#
# It never emits `deny`. Refusal is the permission system's to give.
#
# WHY THE SHAPE MATTERS MORE THAN THE PARSER (refs #290)
#
# The property is unchanged: A DELETION THAT WOULD REMOVE ANY PART OF ANY GIT
# WORKING TREE NEEDS A HUMAN; A DELETION THAT WOULD NOT DOES NOT. It is a
# statement about where bytes live, not about how a command was spelled, and
# a 480-entry list of `Bash(rm ...)` prefix rules could not express it: it
# missed the next caller-chosen variable name AND allowed `rm -rf /tmp/../etc`
# because that string starts with the allowed prefix `rm -rf /tmp/`.
#
# The first fix was to compute the property in a hook and make the hook the
# guard, with the blanket ask removed. Three review rounds then walked past
# it, each time through a shell shape the parser did not model:
#
#     bash <<EOF / rm -rf <repo>/src / EOF   heredoc body read as data
#     sh <<< 'rm -rf <repo>/src'             here-string word discarded
#     bash -c -- 'rm -rf <repo>/src'         bash discards `--`, the guard did not
#     builtin cd <repo> && rm -rf src        tracked cwd desynced -> ALLOW
#     r"m" -rf <repo>/src                    text prefilter never woke up
#
# Each was proven by actually deleting a tracked file out of a real working
# tree. Bash's shapes are not finite, so the lesson is not "model five more".
# It is that a parser over a command STRING cannot be a guard, because the
# string does not become a path until the shell expands it, and the only
# sound answer a string can always give is "I do not know".
#
# So "I do not know" was made safe instead of made rare. With the ask rule
# back, this hook's silence is a human, and every way it can fail -- a
# construct the lexer refuses, a missing jq, an unbound variable, a signal,
# the 10s hook timeout, a command it never woke up for -- is silence. The
# five bypasses above are dead by construction rather than by five branches:
# not one of them can produce an `allow`, and nothing else this hook can do
# is weaker than the human it falls back to.
#
# WHAT THAT LEAVES UNCOVERED, PLAINLY
#
# The ask rule is itself a match on the command text, performed by Claude
# Code and not by this repo. `rm ...` matches it. These do not, and no hook
# can fix that from here, because a PreToolUse hook may only ADD a prompt or
# remove one -- it cannot make the tool call not happen:
#
#   - `/bin/rm -rf <repo>/x` and any other absolute path to rm;
#   - `X=r; ${X}m -rf <repo>/x`, where the two letters are never adjacent;
#   - a deletion that is not rm at all (see OUT OF SCOPE).
#
# For the first two this hook is the only thing that speaks: it lexes
# `/bin/rm` and `r"m"` correctly and will `ask`. That is a courtesy, not a
# guarantee, and it is why the header does not claim one.
#
# THE OPTION THAT WOULD GIVE A GUARANTEE, AND WHY IT IS NOT HERE
#
# Ask the question AFTER expansion, where there is no quoting left to lose:
# an `rm` shim early on the agent shell's PATH that reads its own argv,
# resolves each operand and refuses the ones inside a working tree. The shell
# does the parsing, so all five bypasses stop existing rather than stop
# working. It is installable -- settings.json `env` does reach Bash tool
# calls, and CLAUDE_CODE_SHELL_PREFIX does wrap every one of them -- but it
# needs decisions this file cannot make on its own: `env` values are NOT
# interpolated (no `${PATH}`), so the wrapper path is machine-specific and
# has to come from a per-machine settings.local.json that a fresh clone does
# not have; a shim can only refuse, never ask, so every in-tree deletion
# becomes a hard failure with no in-loop approval; and a broken wrapper takes
# every Bash call in the session with it. See doc/adr/00000015.
#
# HOW THE ALLOW IS COMPUTED
#
# EXTRACTION. The command is lexed with a small shell lexer that models
#   single quotes, double quotes, backslash escapes, `$VAR` / `${VAR}`,
#   `~` / `~/`, the separators `&& || ; | & <newline>`, redirections
#   (including the fd-number prefix), heredocs, here-strings and `#`
#   comments. Each simple command's command word decides what happens:
#     - `rm` (or any `*/rm`)      -> its operands are resolved, one by one;
#     - `bash`/`sh` with `-c`     -> the payload is re-analysed, depth <= 2;
#     - `cd`                      -> moves the effective cwd for the simple
#                                    commands after it, because
#                                    `cd <repo> && rm -rf dist` deletes in
#                                    <repo>;
#     - anything else             -> the tracked cwd is BLANKED (an
#                                    unmodelled command may have moved the
#                                    shell -- `builtin cd`, `command cd`,
#                                    `eval`, a function -- and a stale cwd is
#                                    how a relative operand gets resolved
#                                    against the wrong directory and
#                                    allowed), and if any of its words
#                                    mentions an `rm` token, quoted or not,
#                                    the answer is `ask`: that is
#                                    `xargs rm`, `sudo rm`, `find -exec rm`,
#                                    `git submodule foreach 'rm ...'` and
#                                    every wrapper nobody has written down.
#   NOT LEXED, and therefore never allowed: command substitution `$(...)` and
#   backticks, subshells, arithmetic expansion, `${VAR:-default}` and every
#   other parameter expansion form, positional / special parameters, glob and
#   brace expansion in an operand, `~user`, and an unterminated quote.
#
# ACCOUNTING FOR EVERY WORD. A command is allowable only when nothing in it
#   was skipped. Text the lexer discards as data is still text a shell may
#   execute -- `bash <<EOF ... EOF` and `sh <<< '...'` both run it -- so a
#   heredoc body or a here-string word that mentions an `rm` token makes the
#   whole command un-allowable and produces an `ask`. Likewise `bash -c --`,
#   where real bash discards the `--` and runs the NEXT word: the guard says
#   it cannot place the payload rather than analysing the wrong one.
#
# VARIABLE RESOLUTION. An UNQUOTED expansion is not one word: the shell
#   splits the value on IFS and then expands globs in the pieces, so a value
#   carrying whitespace or a glob character is refused rather than read as a
#   path. Inside double quotes the value is exactly one word and is used as
#   it stands.
#
#   Assignments take effect only from a simple command that was assignments
#   and nothing else (`X=v; rm ...`, `export X=v; rm ...`). A command PREFIX
#   (`X=v rm -rf $X/y`) does not, because bash expands `$X` from the value
#   that existed BEFORE the prefix; applying it made this hook resolve a path
#   bash would not, and allow it. After the command's own assignments comes
#   the environment the hook itself received. A variable that neither
#   supplies is an unknown target. A `bash -c` payload is re-analysed against
#   the ENVIRONMENT ONLY: shell assignments do not cross the boundary, and
#   the conservative side of that mismatch is a prompt.
#
# PATH RESOLUTION. A relative operand is resolved against the invocation cwd
#   (the hook input's `.cwd`), as moved by any `cd` before it; an invocation
#   cwd that does not resolve makes every relative operand unknown. `..` is
#   collapsed and symlinks are resolved PHYSICALLY, by `cd -P`, so
#   `rm -rf /tmp/../etc` resolves to `/etc`. Symlinks in the parent chain are
#   followed; a symlink in the FINAL component is not, because `rm` removes
#   the link and not what it points at.
#
# THE QUESTION, UPWARDS. `git -C <dir> rev-parse --show-toplevel`, where
#   <dir> is the target itself when the target is an existing real directory
#   (so `rm -rf <repo>` is judged inside the tree it would delete) and the
#   target's parent otherwise. For a path that does not exist, the nearest
#   EXISTING ancestor decides. `-c safe.directory='*'` is passed so a
#   host-owned checkout inspected from a container answers "yes, a repo"
#   instead of failing with dubious ownership and being read as "no". git
#   failing for any other reason is an unanswered question.
#
# THE QUESTION, DOWNWARDS. Asking only whether the target is INSIDE a tree
#   would allow `rm -rf <the directory every checkout lives in>`, since that
#   directory is not itself a tree. So a target that is an existing directory
#   outside every tree is searched breadth-first for a `.git` under it, and a
#   hit asks. Breadth-first because the urgent case is shallow. The search
#   does not cross a symlink, since rm -rf does not delete through one, which
#   is also what keeps it finite. ONE budget covers the whole invocation --
#   RMG_SCAN_MAX_DIRS directories and RMG_SCAN_SECONDS seconds shared across
#   every operand, not spent again per operand -- because sixty operands each
#   paying a full budget outlive the hook timeout, and a hook killed for
#   running long emits nothing. Exceeding either budget, or meeting a
#   directory that cannot be read, is an unanswered question.
#
# FLAGS AND SEPARATORS. `--` ends rm's options. A word starting with `-`
# before `--` is a flag. A bare `-` is a filename, as it is for rm itself.
#
# OUT OF SCOPE, named rather than left silently uncovered
#
#   - Deletions that are not `rm`: `find -delete`, `shred`, `truncate`,
#     `trash-put`, `git clean`, `>file`. `git clean` has its own guard;
#     `trash-put` is the recoverable path this repo prefers (`/safe-delete`).
#   - A path that does not exist and whose nearest existing ancestor is
#     outside every repo: allowed. There is nothing there to lose.
#   - A gitignored path INSIDE a repo: asks, same as any other path in the
#     tree. `gitignored` is not a synonym for `safe to lose` -- `.env` is
#     gitignored and hand-written, and so is every `*.local` override in this
#     workspace. Adding `git check-ignore` would spend a second git call to
#     reach a WEAKER answer.
#   - A target outside every working tree that holds none either, including a
#     system path: allowed (the filesystem root itself is not, by any
#     spelling -- `/tmp/..` resolves to it). What stops `rm -rf /etc` is the
#     Bash sandbox's `filesystem.allowWrite` list, not this hook and not the
#     old blanket ask, which allowed `rm -rf /tmp/../etc` outright.
#   - A scratch directory that HOLDS a clone: asks, by the downwards
#     question. A throwaway clone is still a working tree.
#
# THE COST, stated so it is not a surprise: a prompt, never a refusal. An
# `rm` token in a command this hook cannot place produces one even when the
# token is inert -- `echo rm`, `grep 'rm' file`, `git rm README.md`,
# `git commit -m 'drop rm'`. Quoting does not lift it, because quoting is how
# three of the five bypasses hid. What does lift it: a heredoc body with no
# `rm` token, a file instead of an inline string, or running the command
# yourself. `--rm` is not an rm token and `docker run --rm` is silent, as is
# any word with the letters inside it (`confirm-rm-helper`).
#
# Refs: #290 (this hook), #287 / #288 (same defect class, same batch).
# ADR: doc/adr/00000015-rm-safety-lives-in-the-ask.md

set -uo pipefail

# --------------------------------------------------------------------------
# THE PROCESS-LEVEL DEFAULT
#
# Nothing. On purpose, and it is the whole reason this file is safe.
#
# The previous revision printed a `deny` from an EXIT trap, because with the
# blanket ask removed a hook that said nothing was read as consent. That made
# every crash a verdict and every unmodelled shell shape a silent approval --
# the failure this change exists to remove, one level up inside the guard.
#
# With `permissions.ask: Bash(rm:*)` restored, silence means "a human sees
# it". So this hook needs no default of its own: an unbound variable, an
# `exit`, a signal, a missing jq, a hook timeout and a construct the lexer
# refuses all end the process without stdout, and every one of them lands on
# the same human. No trap can be forgotten because there is no trap to write.
#
# The one thing the process must never do is print half a verdict, so the
# JSON is built whole in rmg_emit() before any of it is written.
# --------------------------------------------------------------------------

# Nesting budget for `bash -c '... bash -c "..." ...'`.
readonly RMG_MAX_DEPTH=2

# Byte ceiling for the lexer (see WHAT THIS DELIBERATELY DOES NOT COVER).
readonly RMG_MAX_COMMAND=65536

# Short options a shell takes with NO argument of its own. `c` is handled
# separately; every other character in a bundle must be on this list, or the
# guard cannot say which word is the payload (`-o` takes one, so `-o errexit
# -c ...` would have the guard reading `errexit` as the payload). Anything
# absent -- `o`, `O`, `s`, and whatever a later bash adds -- asks.
readonly RMG_SH_NOARG_FLAGS='abBeEfhHiklmnprtTuvxC'

# The same list for long options, space-delimited on both sides so a
# membership test cannot match a prefix. `--rcfile` / `--init-file` take an
# argument and are deliberately absent.
# Budgets for the containment search (see THE QUESTION in the header). A
# search that exceeds either one is an unanswered question, and an
# unanswered question is never an allow -- so both can be lowered from the
# environment without weakening anything: a smaller budget can only produce
# more prompts, and no value makes an unsearched directory read as ALLOW. The defaults sit
# far below the hook timeout on purpose, because a hook that is killed for
# running long emits nothing at all.
# Validated and clamped rather than trusted: a value that is not a number
# would abort the arithmetic that uses it, and an enormous one would let the
# search outlive the hook timeout -- and a hook killed for running long emits
# nothing, which is the one outcome no verdict can be recovered from.
RMG_SCAN_MAX_DIRS="${RMG_SCAN_MAX_DIRS:-2000}"
[[ "${RMG_SCAN_MAX_DIRS}" =~ ^[0-9]+$ ]] || RMG_SCAN_MAX_DIRS=2000
(( RMG_SCAN_MAX_DIRS > 20000 )) && RMG_SCAN_MAX_DIRS=20000
readonly RMG_SCAN_MAX_DIRS

RMG_SCAN_SECONDS="${RMG_SCAN_SECONDS:-3}"
[[ "${RMG_SCAN_SECONDS}" =~ ^[0-9]+$ ]] || RMG_SCAN_SECONDS=3
(( RMG_SCAN_SECONDS > 5 )) && RMG_SCAN_SECONDS=5
readonly RMG_SCAN_SECONDS

readonly RMG_SH_NOARG_LONG=' --login --noprofile --norc --posix --restricted --verbose --debugger --dump-strings --dump-po-strings --noediting --nolineediting --help --version '

# --------------------------------------------------------------------------
# Lexer
#
# The parser state lives in variables declared `local` in main() and in
# rmg_analyse(): bash's dynamic scoping makes them visible to the helpers
# below without making them process-global, which is what lets rmg_analyse()
# recurse into a `bash -c` payload with its own token stream while the
# caller's is still intact on the stack.
# --------------------------------------------------------------------------

# rmg_end_word -- close the in-progress word and push it, unless it is a
# redirection target we agreed to discard. Also maintains the assignment
# map, because assignment context is a property of position in the token
# stream and this is where position is known.
#
# RMG_SKIP is 1 for a plain redirection target (a filename, inert) and 2 for
# a here-string word, whose reader may be a shell -- `sh <<< 'rm -rf x'`
# executes it. Discarded text that mentions an `rm` token is therefore
# recorded, not dropped: this hook may only ALLOW a command in which every
# word is accounted for.
#
# An assignment is BUFFERED rather than applied. `X=v rm -rf $X/y` is a
# command prefix, and bash expands `$X` from the value that existed BEFORE
# the prefix -- applying it here made the hook resolve a path bash would
# not. The buffer is committed only by rmg_commit_assignments(), which runs
# where a simple command ends, and only when nothing but assignments stood
# in it.
rmg_end_word() {
  local val bad name value
  if (( RMG_WOPEN )); then
    if (( RMG_SKIP )); then
      if (( RMG_SKIP == 2 )) && rmg_mentions_rm "${RMG_W}"; then
        RMG_DATA_RM="a here-string carries an 'rm' this guard cannot place -- its reader may well be a shell, and what it would delete is unknown"
      fi
      RMG_SKIP=0
    else
      val="${RMG_W}"
      bad="${RMG_WBAD}"
      RMG_TOK_VAL+=("${val}")
      RMG_TOK_KIND+=("word")
      RMG_TOK_BAD+=("${bad}")
      RMG_TOK_Q+=("${RMG_WQ}")
      if (( RMG_ASSIGN_CTX )); then
        if [[ "${val}" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
          name="${BASH_REMATCH[1]}"
          value="${val#*=}"
          RMG_PEND_NAME+=("${name}")
          RMG_PEND_VALUE+=("${value}")
          RMG_PEND_BAD+=("${bad}")
        elif [[ "${val}" != export && "${val}" != declare && \
                "${val}" != typeset && "${val}" != local && \
                "${val}" != readonly ]]; then
          # A command word: every assignment before it was that command's
          # environment, not this shell's. Drop them.
          RMG_ASSIGN_CTX=0
          RMG_PEND_NAME=(); RMG_PEND_VALUE=(); RMG_PEND_BAD=()
        fi
      fi
    fi
  fi
  RMG_W=''
  RMG_WBAD=''
  RMG_WQ=0
  RMG_WOPEN=0
}

# rmg_commit_assignments -- apply the buffered assignments of a simple
# command that ended. They take effect only when the command was assignments
# and nothing else (`X=v; ...`, `export X=v; ...`); a prefix (`X=v cmd ...`)
# has already cleared the buffer in rmg_end_word.
rmg_commit_assignments() {
  local k name
  if (( RMG_ASSIGN_CTX )); then
    for (( k = 0; k < ${#RMG_PEND_NAME[@]}; k++ )); do
      name="${RMG_PEND_NAME[k]}"
      if [[ -n "${RMG_PEND_BAD[k]}" ]]; then
        RMG_VARS["${name}"]=''
        RMG_VARS_BAD["${name}"]="${RMG_PEND_BAD[k]}"
      else
        RMG_VARS["${name}"]="${RMG_PEND_VALUE[k]}"
        unset "RMG_VARS_BAD[${name}]"
      fi
    done
  fi
  RMG_PEND_NAME=(); RMG_PEND_VALUE=(); RMG_PEND_BAD=()
}

# rmg_push_sep <text> -- close the in-progress word and push a separator.
rmg_push_sep() {
  rmg_end_word
  rmg_commit_assignments
  RMG_TOK_VAL+=("$1")
  RMG_TOK_KIND+=("sep")
  RMG_TOK_BAD+=("")
  RMG_TOK_Q+=(0)
  RMG_ASSIGN_CTX=1
}

# rmg_value_splits_or_globs <value> -- 0 when the shell would turn <value>,
# expanded UNQUOTED, into something other than the one word it reads as:
# whitespace makes it several operands, and a glob character makes it however
# many paths happen to exist when the command runs. `{` and `}` are refused
# with them although brace expansion happens BEFORE parameter expansion and
# so cannot fire here -- the cost of that is a prompt on a value nobody deletes
# by that name, and the alternative is a reader having to know that ordering
# to check the code.
rmg_value_splits_or_globs() {
  local v="$1"
  [[ "${v}" == *" "* || "${v}" == *$'\t'* || "${v}" == *$'\n'* ]] && return 0
  [[ "${v}" == *'*'* || "${v}" == *'?'* || "${v}" == *'['* || "${v}" == *']'* \
     || "${v}" == *'{'* || "${v}" == *'}'* ]] && return 0
  return 1
}

# rmg_expand_var <name> <quoted> -- append <name>'s value to the in-progress
# word, preferring an assignment seen earlier in this command over the hook's
# own environment. Neither -> the word is unresolvable.
#
# <quoted> is 1 inside double quotes, where the value is exactly one word,
# and 0 outside them, where the shell splits and globs it afterwards. The
# distinction is the whole reason the parameter exists: reading an unquoted
# value as one path is how a variable holding two paths -- one of them inside
# a working tree -- resolved to one path outside every tree and came back
# ALLOW.
rmg_expand_var() {
  local name="$1" quoted="$2" value
  if [[ -n "${RMG_VARS[${name}]+set}" ]]; then
    if [[ -n "${RMG_VARS_BAD[${name}]+set}" ]]; then
      RMG_WBAD="\$${name} was assigned a value this guard cannot resolve"
      return 0
    fi
    value="${RMG_VARS[${name}]}"
  elif [[ -v "${name}" ]]; then
    value="${!name}"
  else
    RMG_WBAD="\$${name} is set neither in the command nor in the environment"
    return 0
  fi
  if (( ! quoted )) && rmg_value_splits_or_globs "${value}"; then
    RMG_WBAD="\$${name} is unquoted and expands to '${value}', which the shell would split or glob into words this guard cannot know before it runs (quoting it makes it one path)"
    return 0
  fi
  RMG_W+="${value}"
}

# rmg_read_dollar <string> <index> <quoted> -- consume the `$...` expansion
# at <index>, appending to the in-progress word. <quoted> is 1 when the
# expansion sits inside double quotes. Sets RMG_NEXT to the index just past
# it. Returns 1 for command / arithmetic substitution, which the caller turns
# into a whole-command parse failure.
rmg_read_dollar() {
  local s="$1" i="$2" quoted="$3"
  local n=${#s}
  local j=$((i + 1))
  local c="${s:j:1}"
  local k body name
  case "${c}" in
    '')
      RMG_W+='$'
      RMG_NEXT=${j}
      ;;
    '(')
      return 1
      ;;
    '{')
      k=$((j + 1))
      body=''
      while (( k < n )) && [[ "${s:k:1}" != '}' ]]; do
        body+="${s:k:1}"
        (( k++ ))
      done
      (( k >= n )) && return 1
      if [[ "${body}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        rmg_expand_var "${body}" "${quoted}"
      else
        RMG_WBAD="\${${body}} is a parameter expansion form this guard does not model"
      fi
      RMG_NEXT=$((k + 1))
      ;;
    [A-Za-z_])
      name=''
      k=${j}
      while (( k < n )) && [[ "${s:k:1}" == [A-Za-z0-9_] ]]; do
        name+="${s:k:1}"
        (( k++ ))
      done
      rmg_expand_var "${name}" "${quoted}"
      RMG_NEXT=${k}
      ;;
    *)
      # The special parameters, tested one literal at a time rather than as
      # a bracket expression: a `case` pattern is expanded before it is
      # matched, and a pattern containing $! aborts this hook under set -u
      # in any shell that never backgrounded a job -- which is every shell
      # this hook runs in. The quoting on each right-hand side below is what
      # keeps these literals literal.
      if [[ "${c}" == [0-9] || "${c}" == '@' || "${c}" == '*' \
         || "${c}" == '?' || "${c}" == '$' || "${c}" == '!' \
         || "${c}" == '#' || "${c}" == '-' ]]; then
        RMG_WBAD="\$${c} is a special parameter this guard does not model"
        RMG_NEXT=$((j + 1))
      else
        RMG_W+='$'
        RMG_NEXT=${j}
      fi
      ;;
  esac
  return 0
}

# rmg_read_heredoc_delimiter <string> <index> -- read the word that ends a
# heredoc, with quoting removed. Sets RMG_HD_DELIM and RMG_NEXT.
rmg_read_heredoc_delimiter() {
  local s="$1" i="$2"
  local n=${#s} delim='' dc
  while (( i < n )); do
    dc="${s:i:1}"
    [[ "${dc}" == ' ' || "${dc}" == $'\t' || "${dc}" == $'\n' ]] && break
    case "${dc}" in
      "'"|'"')
        (( i++ ))
        while (( i < n )) && [[ "${s:i:1}" != "${dc}" ]]; do
          delim+="${s:i:1}"
          (( i++ ))
        done
        (( i++ ))
        ;;
      $'\\')
        (( i++ ))
        delim+="${s:i:1}"
        (( i++ ))
        ;;
      *)
        delim+="${dc}"
        (( i++ ))
        ;;
    esac
  done
  RMG_HD_DELIM="${delim}"
  RMG_NEXT=${i}
}

# rmg_skip_heredoc_bodies <string> <index> -- consume the bodies of every
# heredoc opened on the line just ended. Sets RMG_NEXT.
#
# The body is not an operand, but it is not inert either: `bash <<EOF` runs
# it. So it is read for an `rm` token on the way past, and a body that has
# one makes the command un-allowable rather than invisible.
rmg_skip_heredoc_bodies() {
  local s="$1" i="$2"
  local n=${#s} delim strip line
  while (( ${#RMG_HD[@]} > 0 )); do
    delim="${RMG_HD[0]}"
    strip="${RMG_HDS[0]}"
    RMG_HD=("${RMG_HD[@]:1}")
    RMG_HDS=("${RMG_HDS[@]:1}")
    while (( i < n )); do
      line=''
      while (( i < n )) && [[ "${s:i:1}" != $'\n' ]]; do
        line+="${s:i:1}"
        (( i++ ))
      done
      (( i < n )) && (( i++ ))
      if [[ "${strip}" == 1 ]]; then
        while [[ "${line}" == $'\t'* ]]; do line="${line#$'\t'}"; done
      fi
      [[ "${line}" == "${delim}" ]] && break
      if [[ -z "${RMG_DATA_RM}" ]] && rmg_mentions_rm "${line}"; then
        RMG_DATA_RM="a heredoc body carries an 'rm' this guard cannot place -- its reader may well be a shell, and what it would delete is unknown"
      fi
    done
  done
  RMG_NEXT=${i}
}

# rmg_tokenize <string> -- fill RMG_TOK_* from <string>. Returns 1 when the
# string carries a construct the model does not cover at all.
rmg_tokenize() {
  local s="$1"
  local n=${#s} i=0
  local state=plain
  local c c2 strip

  while (( i < n )); do
    c="${s:i:1}"

    if [[ "${state}" == sq ]]; then
      if [[ "${c}" == "'" ]]; then state=plain; else RMG_W+="${c}"; fi
      (( i++ ))
      continue
    fi

    if [[ "${state}" == dq ]]; then
      case "${c}" in
        '"') state=plain; (( i++ )) ;;
        '`') return 1 ;;
        $'\\')
          c2="${s:i+1:1}"
          case "${c2}" in
            '"'|$'\\'|'$'|'`') RMG_W+="${c2}"; (( i += 2 )) ;;
            *) RMG_W+=$'\\'; (( i++ )) ;;
          esac
          ;;
        '$')
          rmg_read_dollar "${s}" "${i}" 1 || return 1
          i="${RMG_NEXT}"
          ;;
        *) RMG_W+="${c}"; (( i++ )) ;;
      esac
      continue
    fi

    case "${c}" in
      "'") state=sq; RMG_WQ=1; RMG_WOPEN=1; (( i++ )) ;;
      '"') state=dq; RMG_WQ=1; RMG_WOPEN=1; (( i++ )) ;;
      '`') return 1 ;;
      '('|')') return 1 ;;
      $'\\')
        c2="${s:i+1:1}"
        if [[ -z "${c2}" ]]; then
          RMG_W+=$'\\'; RMG_WOPEN=1; (( i++ ))
        elif [[ "${c2}" == $'\n' ]]; then
          (( i += 2 ))
        else
          RMG_W+="${c2}"; RMG_WQ=1; RMG_WOPEN=1; (( i += 2 ))
        fi
        ;;
      '$')
        RMG_WOPEN=1
        rmg_read_dollar "${s}" "${i}" 0 || return 1
        i="${RMG_NEXT}"
        ;;
      ' '|$'\t') rmg_end_word; (( i++ )) ;;
      $'\n')
        rmg_push_sep ';'
        (( i++ ))
        rmg_skip_heredoc_bodies "${s}" "${i}"
        i="${RMG_NEXT}"
        ;;
      ';') rmg_push_sep ';'; (( i++ )) ;;
      '&')
        if [[ "${s:i+1:1}" == '&' ]]; then rmg_push_sep '&&'; (( i += 2 ))
        else rmg_push_sep '&'; (( i++ )); fi
        ;;
      '|')
        if [[ "${s:i+1:1}" == '|' ]]; then rmg_push_sep '||'; (( i += 2 ))
        else rmg_push_sep '|'; (( i++ )); fi
        ;;
      '<'|'>')
        if [[ "${c}" == '<' && "${s:i+1:1}" == '<' ]]; then
          rmg_end_word
          (( i += 2 ))
          strip=0
          if [[ "${s:i:1}" == '-' ]]; then strip=1; (( i++ )); fi
          if [[ "${s:i:1}" == '<' ]]; then
            # `<<<` here-string: its word is data, but data a shell may
            # execute, so it is discarded as an operand and still read.
            (( i++ )); RMG_SKIP=2; continue
          fi
          while [[ "${s:i:1}" == ' ' || "${s:i:1}" == $'\t' ]]; do (( i++ )); done
          rmg_read_heredoc_delimiter "${s}" "${i}"
          i="${RMG_NEXT}"
          RMG_HD+=("${RMG_HD_DELIM}")
          RMG_HDS+=("${strip}")
          continue
        fi
        # A leading fd number belongs to the redirection, not to the word.
        if (( RMG_WOPEN )) && (( RMG_WQ == 0 )) && [[ "${RMG_W}" =~ ^[0-9]+$ ]]; then
          RMG_W=''
          RMG_WOPEN=0
        fi
        rmg_end_word
        (( i++ ))
        if [[ "${s:i:1}" == '>' || "${s:i:1}" == '&' ]]; then (( i++ )); fi
        RMG_SKIP=1
        ;;
      '#')
        if (( RMG_WOPEN )); then
          RMG_W+='#'; (( i++ ))
        else
          while (( i < n )) && [[ "${s:i:1}" != $'\n' ]]; do (( i++ )); done
        fi
        ;;
      '~')
        if (( RMG_WOPEN )); then
          RMG_W+='~'
        else
          c2="${s:i+1:1}"
          if [[ -z "${c2}" || "${c2}" == '/' || "${c2}" == ' ' || "${c2}" == $'\t' ]]; then
            if [[ -n "${HOME:-}" ]]; then
              RMG_W+="${HOME}"
            else
              RMG_WBAD="~ cannot expand because HOME is unset"
            fi
          else
            RMG_WBAD='~user is a tilde expansion form this guard does not model'
          fi
        fi
        RMG_WOPEN=1
        (( i++ ))
        ;;
      '*'|'?'|'['|']'|'{'|'}')
        RMG_WBAD="'${c}' makes this word a glob or brace expansion, whose matches are not known until the shell runs"
        RMG_W+="${c}"
        RMG_WOPEN=1
        (( i++ ))
        ;;
      *)
        RMG_W+="${c}"
        RMG_WOPEN=1
        (( i++ ))
        ;;
    esac
  done

  [[ "${state}" != plain ]] && return 1
  rmg_end_word
  rmg_commit_assignments
  return 0
}

# --------------------------------------------------------------------------
# Target resolution
# --------------------------------------------------------------------------

# rmg_resolve_target <absolute path> -- resolve <path> physically, as far as
# it exists, and name the directory whose repository decides for it. Returns
# 1 when neither is knowable. Sets:
#
#   RMG_PHYS    the target with `..` collapsed and symlinks in its parent
#               chain followed -- what the message should print, since the
#               spelling is the half the reader already has;
#   RMG_ANCHOR  the existing directory git is asked about: the target itself
#               when it is one, otherwise the target's parent, otherwise the
#               nearest existing ancestor;
#   RMG_IS_DIR  1 when the target IS that directory, which is the only case
#               with anything underneath it to lose.
rmg_resolve_target() {
  local p="$1" suffix='' base dir out
  RMG_PHYS=''
  RMG_ANCHOR=''
  RMG_IS_DIR=0
  while :; do
    # A symlink AS THE TARGET is judged where the link lives: rm removes the
    # link, not what it points at. A symlink in the parent chain is followed,
    # because rm deletes through it.
    if [[ -L "${p}" && -z "${suffix}" ]] || { [[ -e "${p}" && ! -d "${p}" ]]; }; then
      # Not something to enter. As the target, its parent decides; as an
      # ancestor, the path cannot resolve at all (rm gets ENOTDIR).
      [[ -n "${suffix}" ]] && return 1
      base="${p##*/}"
      dir="${p%/*}"
      [[ -z "${dir}" ]] && dir="/"
      out="$(cd -P -- "${dir}" 2>/dev/null && pwd -P)" || return 1
      [[ -z "${out}" ]] && return 1
      RMG_ANCHOR="${out}"
      RMG_PHYS="${out%/}/${base}"
      return 0
    fi
    if [[ -d "${p}" ]]; then
      out="$(cd -P -- "${p}" 2>/dev/null && pwd -P)" || return 1
      [[ -z "${out}" ]] && return 1
      RMG_ANCHOR="${out}"
      if [[ -n "${suffix}" ]]; then
        RMG_PHYS="${out%/}${suffix}"
      else
        # `${out%/}` would empty the root itself, and the root is the one
        # path this hook must still be able to name.
        RMG_PHYS="${out}"
        RMG_IS_DIR=1
      fi
      return 0
    fi
    [[ "${p}" == "/" ]] && return 1
    base="${p##*/}"
    suffix="/${base}${suffix}"
    p="${p%/*}"
    [[ -z "${p}" ]] && p="/"
  done
}

# rmg_in_git_tree <dir> -- 0 inside a working tree, 1 definitively outside,
# 2 unknown (which the caller fails closed on). Sets RMG_TREE_TOP to the
# tree's ROOT on 0, because that is the fact a reader can act on -- the
# directory that happened to be probed is not.
rmg_in_git_tree() {
  local dir="$1" out rc
  if [[ -n "${RMG_GIT_CACHE[${dir}]+set}" ]]; then
    RMG_TREE_TOP="${RMG_GIT_TOP[${dir}]}"
    return "${RMG_GIT_CACHE[${dir}]}"
  fi
  RMG_TREE_TOP=''
  out="$(LC_ALL=C git -c safe.directory='*' -C "${dir}" \
    rev-parse --show-toplevel 2>&1)"
  rc=$?
  if (( rc == 0 )); then
    if [[ -n "${out}" ]]; then rc=0; RMG_TREE_TOP="${out}"; else rc=2; fi
  elif [[ "${out}" == *"not a git repository"* ]]; then
    rc=1
  else
    rc=2
  fi
  RMG_GIT_CACHE["${dir}"]="${rc}"
  RMG_GIT_TOP["${dir}"]="${RMG_TREE_TOP}"
  return "${rc}"
}

# rmg_contains_git_tree <dir> -- 0 when a git working tree lives somewhere
# under <dir> (RMG_FOUND_TREE names it), 1 when none does, 2 when the search
# could not finish and the answer is therefore unknown.
#
# Breadth-first, so the shallow repositories that make this question urgent
# -- a workspace directory holding a dozen checkouts -- are found in the
# first few directories examined rather than after a full descent. The search
# does not cross a symlink, because `rm -rf` does not delete through one
# either, and that is also what keeps the walk finite.
rmg_contains_git_tree() {
  local root="$1"
  local -a queue=("${root}")
  RMG_FOUND_TREE=''
  local head=0 dir entry rc=1
  local had_nullglob=0 had_dotglob=0
  shopt -q nullglob && had_nullglob=1
  shopt -q dotglob && had_dotglob=1
  shopt -s nullglob dotglob
  while (( head < ${#queue[@]} )); do
    dir="${queue[head]}"
    (( head++ ))
    (( RMG_SCAN_USED++ ))
    if (( RMG_SCAN_USED > RMG_SCAN_MAX_DIRS )) \
      || (( SECONDS - RMG_SCAN_T0 > RMG_SCAN_SECONDS )); then
      rc=2
      break
    fi
    if [[ -e "${dir}/.git" ]]; then
      RMG_FOUND_TREE="${dir}"
      rc=0
      break
    fi
    if [[ ! -r "${dir}" || ! -x "${dir}" ]]; then
      RMG_FOUND_TREE="${dir}"
      rc=2
      break
    fi
    for entry in "${dir}"/*; do
      [[ -L "${entry}" ]] && continue
      [[ -d "${entry}" ]] || continue
      queue+=("${entry}")
    done
  done
  (( had_nullglob )) || shopt -u nullglob
  (( had_dotglob )) || shopt -u dotglob
  return "${rc}"
}

# rmg_operand_verdict <operand> -- 0 when the operand resolves outside every
# git working tree, 2 (with RMG_REASON set) otherwise.
rmg_operand_verdict() {
  local operand="$1" abs

  if [[ -z "${operand}" ]]; then
    RMG_REASON="rm was given an empty operand, so its target is unknown"
    return 2
  fi

  if [[ "${operand}" == /* ]]; then
    abs="${operand}"
  else
    if [[ -z "${RMG_CWD_PHYS}" ]]; then
      if [[ -n "${RMG_CWD_LOST}" ]]; then
        RMG_REASON="rm operand '${operand}' is relative and ${RMG_CWD_LOST}, so the directory it would be deleted from is unknown"
      else
        RMG_REASON="rm operand '${operand}' is relative and the invocation cwd (${RMG_CWD:-unset}) does not resolve, so its target is unknown"
      fi
      return 2
    fi
    abs="${RMG_CWD_PHYS}/${operand}"
  fi

  while [[ "${abs}" == */ && "${abs}" != "/" ]]; do abs="${abs%/}"; done

  if [[ "${abs}" == "/" ]]; then
    RMG_REASON="rm operand '${operand}' resolves to the filesystem root, which is never a routine deletion"
    return 2
  fi

  if ! rmg_resolve_target "${abs}"; then
    RMG_REASON="rm operand '${operand}' has no resolvable directory (${abs}), and an unresolvable target is an unknown target"
    return 2
  fi

  # The root under another spelling -- `/tmp/..`, `/x/../..` -- is the root.
  if [[ "${RMG_PHYS}" == "/" ]]; then
    RMG_REASON="rm operand '${operand}' resolves to the filesystem root, which is never a routine deletion"
    return 2
  fi

  rmg_in_git_tree "${RMG_ANCHOR}"
  case "$?" in
    0)
      RMG_REASON="rm operand '${operand}' resolves to ${RMG_PHYS}, inside the git working tree at ${RMG_TREE_TOP}. A deletion inside a working tree needs a human: run it yourself, or use 'trash-put' (/safe-delete) or 'git rm', which are recoverable"
      return 2
      ;;
    1)
      # Outside every tree -- but a directory that HOLDS trees would take
      # them with it, so the same question is asked downwards. Only for a
      # directory the target actually is: a file, a symlink and a path that
      # does not exist have nothing under them to lose.
      if (( RMG_IS_DIR )); then
        rmg_contains_git_tree "${RMG_PHYS}"
        case "$?" in
          0)
            RMG_REASON="rm operand '${operand}' resolves to ${RMG_PHYS}, which is not itself a git working tree but contains the git working tree at ${RMG_FOUND_TREE}. Deleting it would take that tree with it, so it needs a human: run it yourself, or use 'trash-put' (/safe-delete), which is recoverable"
            return 2
            ;;
          2)
            RMG_REASON="rm operand '${operand}' resolves to ${RMG_PHYS}, and the guard could not finish searching it for git working trees within its budget (${RMG_SCAN_MAX_DIRS} directories / ${RMG_SCAN_SECONDS}s, stopped at ${RMG_FOUND_TREE:-${RMG_PHYS}}). Whether this deletion would take a working tree with it is therefore unknown"
            return 2
            ;;
        esac
      fi
      return 0
      ;;
    *)
      RMG_REASON="git could not say whether ${RMG_ANCHOR} is a working tree, and an unanswered question is an unknown target"
      return 2
      ;;
  esac
}

# --------------------------------------------------------------------------
# Walk
# --------------------------------------------------------------------------

# rmg_apply_cd <token index...> -- move the effective cwd, or blank it when
# the destination is not knowable from the command text alone.
rmg_apply_cd() {
  local t v bad target='' abs
  for t in "$@"; do
    v="${RMG_TOK_VAL[t]}"
    bad="${RMG_TOK_BAD[t]}"
    if [[ -z "${bad}" && "${v}" == -?* ]]; then continue; fi
    if [[ -n "${bad}" ]]; then RMG_CWD_PHYS=''; return 0; fi
    target="${v}"
    break
  done
  [[ -z "${target}" ]] && target="${HOME:-}"
  if [[ -z "${target}" || "${target}" == "-" ]]; then
    RMG_CWD_PHYS=''
    return 0
  fi
  if [[ "${target}" == /* ]]; then
    abs="${target}"
  else
    [[ -z "${RMG_CWD_PHYS}" ]] && return 0
    abs="${RMG_CWD_PHYS}/${target}"
  fi
  RMG_CWD_PHYS="$(cd -P -- "${abs}" 2>/dev/null && pwd -P)" || RMG_CWD_PHYS=''
  return 0
}

# rmg_check_rm <token index...> -- the arguments of one `rm` invocation.
# 1 when every operand is outside a working tree, 2 (RMG_REASON) otherwise.
rmg_check_rm() {
  local -a idx=("$@")
  local saw_dashdash=0 k=0 t v bad
  while (( k < ${#idx[@]} )); do
    t="${idx[k]}"
    v="${RMG_TOK_VAL[t]}"
    bad="${RMG_TOK_BAD[t]}"
    (( k++ ))
    if (( ! saw_dashdash )) && [[ -z "${bad}" ]]; then
      if [[ "${v}" == "--" ]]; then saw_dashdash=1; continue; fi
      if [[ "${v}" == -?* ]]; then continue; fi
    fi
    if [[ -n "${bad}" ]]; then
      RMG_REASON="an rm operand cannot be resolved: ${bad}. An unresolved target is an unknown target"
      return 2
    fi
    rmg_operand_verdict "${v}" || return 2
  done
  return 1
}

# rmg_unmodelled_rm <command word> <token index...> -- 2 when any word of a
# command this hook cannot place mentions an `rm` token, 0 otherwise.
#
# The test is on the TOKEN, not on the quoting. The older rule -- an
# UNQUOTED word equal to `rm` -- reads as a rule about invocations and is
# really a rule about quoting: it stopped `xargs rm -rf` and let
# `xargs -I{} sh -c 'rm -rf <repo>'` through silently, one quote further in.
# Telling an executing word from an inert one needs each wrapper's
# semantics, and enumerating wrappers is the mechanism this hook replaces.
#
# The cost is that an inert mention is asked about too -- `echo 'rm -rf x'`,
# `grep rm file`, `git rm README.md` -- and quoting no longer lifts it,
# because quoting is how the wrapper cases hid. `git` used to be skipped with
# its words on the grounds that `git rm` stages a recoverable deletion; that
# also made `git submodule foreach 'rm -rf <repo>/src'` invisible, so the
# special case is gone and git reaches this rule like every other wrapper.
rmg_unmodelled_rm() {
  local cmdword="$1"
  shift
  local t
  for t in "$@"; do
    if rmg_mentions_rm "${RMG_TOK_VAL[t]}"; then
      RMG_REASON="'${cmdword}' is a command this guard does not model and one of its words mentions 'rm', so what it would delete is unknown. Approve it only if you know what it removes; running the rm as its own command lets the guard resolve the target instead"
      return 2
    fi
  done
  return 0
}

# rmg_shell_payload <base> <token index...> -- find the `-c` payload of a
# shell invocation. 0 with RMG_PAYLOAD set, 1 when the invocation has no
# `-c` at all, 2 (RMG_REASON) when the payload's position is not knowable.
#
# `-c` is not always the last character of its bundle: bash runs the payload
# of `bash -cx '...'` exactly as it runs `bash -xc '...'`. So the bundle is
# read character by character, and every character other than `c` has to be
# an option that takes no argument -- otherwise the word after the bundle
# might be that option's argument rather than the payload, and a guard that
# guesses is a guard that can be aimed.
rmg_shell_payload() {
  local base="$1"
  shift
  local -a idx=("$@")
  local n=$# j=0 w rest ch i
  while (( j < n )); do
    w="${RMG_TOK_VAL[${idx[j]}]}"
    if [[ -n "${RMG_TOK_BAD[${idx[j]}]}" ]]; then
      RMG_REASON="an argument of '${base}' cannot be resolved: ${RMG_TOK_BAD[${idx[j]}]}, so its payload is unknown"
      return 2
    fi
    # A word that is not an option ends them: from here on this is a script
    # name and its arguments, not a payload.
    #
    # `--` is NOT that word. Real bash DISCARDS it and reads the next word as
    # the command string, so `bash -c -- '<payload>'` runs the payload while a
    # guard that treats `--` as end-of-options analyses the string `--` and
    # sees nothing. Rather than model one more spelling, the guard says it
    # cannot place the payload, which costs a prompt and cannot cost a file.
    if [[ "${w}" == "--" ]]; then
      RMG_REASON="'${base} --' places the payload somewhere this guard does not model, so what it would delete is unknown"
      return 2
    fi
    if [[ "${w}" != -?* ]]; then
      return 1
    fi
    if [[ "${w}" == --* ]]; then
      if [[ "${RMG_SH_NOARG_LONG}" != *" ${w} "* ]]; then
        RMG_REASON="'${base} ${w}' is a shell option this guard does not model, so it cannot say which word is the '-c' payload"
        return 2
      fi
      (( j++ ))
      continue
    fi
    rest="${w#-}"
    for (( i = 0; i < ${#rest}; i++ )); do
      ch="${rest:i:1}"
      [[ "${ch}" == "c" ]] && continue
      if [[ "${RMG_SH_NOARG_FLAGS}" != *"${ch}"* ]]; then
        RMG_REASON="'${base} ${w}' bundles a shell option this guard does not model, so it cannot say which word is the '-c' payload"
        return 2
      fi
    done
    if [[ "${rest}" == *c* ]]; then
      if (( j + 1 >= n )); then
        RMG_REASON="a '${base} -c' invocation with no payload cannot be checked"
        return 2
      fi
      if [[ -n "${RMG_TOK_BAD[${idx[j+1]}]}" ]]; then
        RMG_REASON="the '${base} -c' payload cannot be resolved: ${RMG_TOK_BAD[${idx[j+1]}]}"
        return 2
      fi
      # Real bash DISCARDS a `--` here and runs the word after it, so the
      # word this guard can see is not the one that executes.
      if [[ "${RMG_TOK_VAL[${idx[j+1]}]}" == "--" ]]; then
        RMG_REASON="'${base} -c --' places the payload somewhere this guard does not model, so what it would delete is unknown"
        return 2
      fi
      RMG_PAYLOAD="${RMG_TOK_VAL[${idx[j+1]}]}"
      return 0
    fi
    (( j++ ))
  done
  return 1
}

# rmg_simple_command <depth> <token index...> -- classify one simple
# command. 0 no rm, 1 rm and every target is outside, 2 ask (RMG_REASON).
rmg_simple_command() {
  local depth="$1"
  shift
  local -a idx=("$@")
  local k=0 count=${#idx[@]} cmdword base

  while (( k < count )) \
    && [[ "${RMG_TOK_VAL[${idx[k]}]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    (( k++ ))
  done
  (( k >= count )) && return 0

  cmdword="${RMG_TOK_VAL[${idx[k]}]}"
  base="${cmdword##*/}"

  case "${base}" in
    rm)
      rmg_check_rm "${idx[@]:k+1}"
      return $?
      ;;
    cd)
      # `cd <dir> && rm <relative>` deletes in <dir>, not in the invocation
      # cwd. Track it, and treat a cd we cannot follow as an unknown cwd, so
      # every later relative operand is unresolved instead of resolving
      # somewhere the command will not be.
      rmg_apply_cd "${idx[@]:k+1}"
      return 0
      ;;
    bash|sh|dash|zsh)
      # A shell can chdir whatever it likes before it returns.
      RMG_CWD_PHYS=''
      RMG_CWD_LOST="an earlier '${cmdword}' in the same command may have moved the shell"
      rmg_shell_payload "${base}" "${idx[@]:k+1}"
      case "$?" in
        0)
          if (( depth + 1 > RMG_MAX_DEPTH )); then
            RMG_REASON="'${base} -c' is nested deeper than this guard follows (${RMG_MAX_DEPTH}), so its targets are unknown"
            return 2
          fi
          rmg_analyse_nested "${RMG_PAYLOAD}" $((depth + 1))
          return $?
          ;;
        2) return 2 ;;
      esac
      rmg_unmodelled_rm "${cmdword}" "${idx[@]:k+1}" || return 2
      return 0
      ;;
    *)
      # Anything this guard does not model may have moved the shell, and
      # `builtin cd <repo> && rm -rf src` proved that guessing it did not is
      # how a relative operand gets resolved against the wrong directory and
      # ALLOWED. Only the two commands modelled above leave the tracked cwd
      # standing; every other one blanks it, so a later relative operand is
      # unknown and goes to a human. One rule, no list of builtins to keep
      # up with.
      RMG_CWD_PHYS=''
      RMG_CWD_LOST="an earlier '${cmdword}' in the same command may have moved the shell"
      rmg_unmodelled_rm "${cmdword}" "${idx[@]:k+1}" || return 2
      return 0
      ;;
  esac
}

# rmg_walk <depth> -- split the token stream into simple commands and
# classify each. 0 no rm, 1 rm and every target is outside, 2 ask.
rmg_walk() {
  local depth="$1"
  local n=${#RMG_TOK_VAL[@]}
  local i=0 found=0 rc
  local -a cur=()
  while (( i <= n )); do
    if (( i == n )) || [[ "${RMG_TOK_KIND[i]}" == "sep" ]]; then
      if (( ${#cur[@]} > 0 )); then
        rmg_simple_command "${depth}" "${cur[@]}"
        rc=$?
        (( rc == 2 )) && return 2
        (( rc == 1 )) && found=1
        cur=()
      fi
    else
      cur+=("${i}")
    fi
    (( i++ ))
  done
  (( found )) && return 1
  return 0
}

# rmg_analyse <command> <depth> -- tokenize and walk one command string.
# 0 no rm, 1 allow, 2 ask (RMG_REASON set).
rmg_analyse() {
  local cmd="$1" depth="$2"
  # Per-frame parser state; see the Lexer note above on dynamic scoping.
  local -a RMG_TOK_VAL=() RMG_TOK_KIND=() RMG_TOK_BAD=() RMG_TOK_Q=()
  local -a RMG_HD=() RMG_HDS=()
  local -a RMG_PEND_NAME=() RMG_PEND_VALUE=() RMG_PEND_BAD=()
  local RMG_W='' RMG_WBAD='' RMG_WQ=0 RMG_WOPEN=0 RMG_SKIP=0
  local RMG_NEXT=0 RMG_HD_DELIM='' RMG_ASSIGN_CTX=1 RMG_DATA_RM=''
  local rc

  if (( ${#cmd} > RMG_MAX_COMMAND )); then
    RMG_REASON="the command is longer than ${RMG_MAX_COMMAND} bytes, which this guard does not parse, so its rm targets are unknown"
    return 2
  fi
  if ! rmg_tokenize "${cmd}"; then
    RMG_REASON="the command uses a construct this guard does not parse (command substitution, a subshell, or an unterminated quote), so its rm targets are unknown"
    return 2
  fi
  rmg_walk "${depth}"
  rc=$?
  # Text the lexer discarded as data is still text a shell may execute. A
  # command carrying one is never allowed, whatever its own operands say.
  if (( rc != 2 )) && [[ -n "${RMG_DATA_RM}" ]]; then
    RMG_REASON="${RMG_DATA_RM}"
    return 2
  fi
  return "${rc}"
}

# rmg_analyse_nested <payload> <depth> -- analyse a `bash -c` payload with a
# fresh variable map: only the environment crosses the boundary.
rmg_analyse_nested() {
  local -A RMG_VARS=() RMG_VARS_BAD=()
  local RMG_CWD_PHYS="${RMG_CWD_PHYS}" RMG_CWD_LOST="${RMG_CWD_LOST}"
  rmg_analyse "$1" "$2"
}

# --------------------------------------------------------------------------

# rmg_mentions_rm <command> -- cheap gate so a command with no `rm` word in
# it is never lexed.
#
# It is a TEXT match, which is the mechanism this hook replaces, and it is
# only sound here because of which way it can be wrong: a miss produces
# SILENCE, and silence is the ask rule, i.e. a human. It never produces an
# allow. Quote characters are stripped first, so `r"m"`, `r'"'"'m'"'"'` and
# `r\m` -- each of which the shell runs as `rm`, and each of which walked
# past the previous revision -- reach the lexer, which normalises them
# properly. Both spellings are tried, raw and stripped, so removing the
# quotes can only widen the gate and never narrow it. A spelling that survives even that (`X=r; ${X}m ...`) is not
# lexed and gets the human by default.
rmg_mentions_rm() {
  local t
  [[ "$1" =~ (^|[^A-Za-z0-9_.-])rm([^A-Za-z0-9_.-]|$) ]] && return 0
  t="${1//[\'\"\\]/}"
  [[ "${t}" =~ (^|[^A-Za-z0-9_.-])rm([^A-Za-z0-9_.-]|$) ]]
}

# rmg_emit <decision> <reason> -- print one verdict, or print nothing. The
# JSON is built whole before any of it is written, so a failure inside jq
# cannot leave half a verdict on stdout for the caller to parse. A jq that
# does not run therefore produces silence, which is the ask rule.
rmg_emit() {
  local out
  out="$(jq -n --arg d "$1" --arg r "$2" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $d,
      permissionDecisionReason: $r
    }
  }')" || return 0
  [[ -n "${out}" ]] || return 0
  printf '%s\n' "${out}"
}

# rmg_run -- read the hook input, decide, emit. Everything that can fail
# lives here; main() exists only to record that it did not.
rmg_run() {
  local input cmd rc
  # Parser + verdict state, local to main so nothing leaks between hook runs.
  local RMG_CWD='' RMG_CWD_PHYS='' RMG_REASON='' RMG_PAYLOAD='' RMG_FOUND_TREE=''
  local RMG_CWD_LOST=''
  local RMG_PHYS='' RMG_ANCHOR='' RMG_IS_DIR=0 RMG_TREE_TOP=''
  # One containment-search budget for the whole invocation, not one per
  # operand: sixty operands each paying a full per-operand budget outlive the
  # hook timeout, and a hook killed for running long is not a verdict.
  local RMG_SCAN_USED=0 RMG_SCAN_T0="${SECONDS}"
  local -A RMG_VARS=() RMG_VARS_BAD=() RMG_GIT_CACHE=() RMG_GIT_TOP=()

  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [[ -z "${cmd}" ]] && return 0
  rmg_mentions_rm "${cmd}" || return 0

  # Byte semantics for the lexer, and a git that cannot be redirected at a
  # different repository by the ambient environment.
  export LC_ALL=C
  unset GIT_DIR GIT_WORK_TREE GIT_CEILING_DIRECTORIES CDPATH

  RMG_CWD="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
  [[ -z "${RMG_CWD}" ]] && RMG_CWD="${PWD:-}"
  if [[ -n "${RMG_CWD}" ]]; then
    RMG_CWD_PHYS="$(cd -P -- "${RMG_CWD}" 2>/dev/null && pwd -P)" || RMG_CWD_PHYS=''
  fi

  rmg_analyse "${cmd}" 0
  rc=$?
  case "${rc}" in
    0) return 0 ;;
    1) rmg_emit allow "every rm target resolves outside any git working tree" ;;
    *) rmg_emit ask "${RMG_REASON}" ;;
  esac
  return 0
}

# main -- the whole of the hook. Every way out of it that is not a verdict
# is silence, and silence is the ask rule.
main() {
  rmg_run
}

main "$@"
