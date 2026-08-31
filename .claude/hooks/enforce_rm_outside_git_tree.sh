#!/usr/bin/env bash
# enforce_rm_outside_git_tree.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# THE PROPERTY, stated positively:
#
#   A deletion whose RESOLVED TARGET is inside a git working tree needs a
#   human; a deletion anywhere else does not.
#
# That is a statement about where the bytes live, not about how the command
# was spelled. This hook computes it: it extracts every `rm` invocation from
# the command, resolves each operand to an absolute physical path, and asks
# git one question per target.
#
# WHY THIS REPLACES A PREFIX-MATCH ALLOW LIST (refs #290)
#
# `permissions.ask: Bash(rm:*)` plus a list of `Bash(rm ...)` allow rules
# expressed the same intent as a set of literal prefix matches over the
# command STRING. It was widened three times in one afternoon and lost three
# times, because the spelling is the caller's to choose:
#
#   rm -rf "$TMPDIR/mut957"          the opening quote precedes the variable
#   SCRATCH=...; rm -rf $SCRATCH/x   the variable name is caller-chosen
#   export T=...; rm -rf "$T/a1"     ... and can be a single letter
#
# At 480 rules it was still incomplete (the next variable name misses) AND
# unsound in the other direction (`rm -rf /tmp/../etc` begins with the
# allowed prefix `rm -rf /tmp/`). A guard that both under- and over-matches
# is not a narrow version of the property; it is a different property that
# happens to correlate. The answer this hook computes does not depend on
# quote placement, variable name or flag order, so none of those can be the
# next miss.
#
# DECISIONS, so the next reader can check the code against them rather than
# against an intention:
#
# EXTRACTION. The command is tokenized with a small shell lexer that models
#   single quotes, double quotes, backslash escapes, `$VAR` / `${VAR}`,
#   `~` / `~/`, the separators `&& || ; | & <newline>`, redirections
#   (including the fd-number prefix and here-strings), heredoc bodies (which
#   are DATA and are skipped whole), and `#` comments. Each simple command's
#   command word decides what happens:
#     - `rm` (or any `*/rm`)      -> its operands are checked, one by one;
#     - `bash`/`sh` with `-c`     -> the payload is re-analysed, depth <= 2;
#     - `git`                     -> skipped, see OUT OF SCOPE below;
#     - `cd`                      -> moves the effective cwd for the simple
#                                    commands after it, because
#                                    `cd <repo> && rm -rf dist` deletes in
#                                    <repo>; a `cd` whose destination is not
#                                    knowable blanks the cwd instead, so
#                                    every later relative operand denies;
#     - anything else             -> if an unquoted literal `rm` token
#                                    appears among its words, DENY: that is
#                                    `xargs rm`, `sudo rm`, `find -exec rm`
#                                    and every wrapper nobody has written
#                                    down yet, and we cannot tell an
#                                    executing position from an inert one
#                                    without knowing the wrapper's
#                                    semantics.
#   NOT PARSED, and therefore DENIED when the command mentions `rm` at all:
#   command substitution `$(...)` and backticks, subshells `( ... )`,
#   arithmetic expansion, `${VAR:-default}` and every other parameter
#   expansion form, positional / special parameters (`$1`, `$@`, `$?`),
#   glob and brace expansion in an operand, `~user`, and an unterminated
#   quote. An unparsed command is an unknown target, and the default on
#   unrecognised input is the whole point of this change.
#
# VARIABLE RESOLUTION. Assignments that appear earlier in the same command
#   (`VAR=...`, and `export`/`declare`/`typeset`/`local`/`readonly`
#   prefixes) are applied, then the environment the hook itself receives. A
#   variable that neither supplies is an unknown target: DENY. A `bash -c`
#   payload is re-analysed against the ENVIRONMENT ONLY -- shell assignments
#   from the enclosing command do not cross the boundary. Real bash crosses
#   only the exported ones, and modelling that difference buys nothing: the
#   conservative side of the mismatch is a DENY.
#
# PATH RESOLUTION. A relative operand is resolved against the invocation cwd
#   (the hook input's `.cwd`); an invocation cwd that does not resolve makes
#   every relative operand unknown: DENY. `..` is collapsed and symlinks are
#   resolved PHYSICALLY, by `cd -P`, so `rm -rf /tmp/../etc` resolves to
#   `/etc`. Symlinks in the parent chain are followed; a symlink in the FINAL
#   component is not, because `rm` removes the link and not what it points
#   at -- so a link in /tmp that aims at a repo is judged where the link
#   lives.
#
# THE QUESTION. `git -C <dir> rev-parse --show-toplevel`, where <dir> is the
#   target itself when the target is an existing real directory (so
#   `rm -rf <repo>` is judged inside the tree it would delete) and the
#   target's parent otherwise. For a path that does not exist, the nearest
#   EXISTING ancestor decides. `-c safe.directory='*'` is passed so a
#   host-owned checkout inspected from a container answers "yes, a repo"
#   instead of failing with dubious ownership and being read as "no".
#   git failing for any reason other than "not a git repository" is an
#   unknown answer: DENY.
#
# FLAGS AND SEPARATORS. `--` ends options. A word starting with `-` before
#   `--` is a flag. A bare `-` is a filename, as it is for rm itself.
#
# WHAT THIS DELIBERATELY DOES NOT COVER
#
#   - A path that does not exist and whose nearest existing ancestor is
#     outside every repo: ALLOWED. There is nothing there to lose.
#   - A path whose directory cannot be resolved: DENIED. Unresolvable means
#     unknown, and this is the one place the hook must fail closed.
#   - Deletions that are not `rm`: `find -delete`, `shred`, `truncate`,
#     `trash-put`, `git clean`, `git rm`, `>file`. Out of scope, named here
#     rather than left silently uncovered. `git clean` has its own guard;
#     `trash-put` is the recoverable path this repo prefers (`/safe-delete`);
#     `git rm` stages a deletion git can restore. A `git` simple command is
#     therefore skipped whole.
#   - A gitignored path INSIDE a repo: DENIED, same as any other path in the
#     tree. `gitignored` is not a synonym for `safe to lose` -- `.env` is
#     gitignored and hand-written, and so is every `*.local` override in
#     this workspace. The cheap-to-compute question ("is it in the tree?")
#     is also the one that matches the risk; adding `git check-ignore` would
#     spend a second git call to reach a WEAKER answer.
#   - A target outside every git working tree, including a system path:
#     ALLOWED (only the filesystem root itself is refused). This hook owns
#     the "is it somebody's source tree?" question and nothing else. What
#     stops `rm -rf /etc` is the Bash sandbox's `filesystem.allowWrite`
#     list, which `rm` is not excluded from -- the old blanket ask rule was
#     not that guard either, since it allowed `rm -rf /tmp/../etc` outright.
#   - A command longer than RMG_MAX_COMMAND bytes: DENIED unparsed. The
#     lexer is O(n^2) in bash and the hook has a 10s budget.
#
# COST, stated so it is not a surprise: an unquoted `rm` word in a command
# this hook does not model is denied even when it is inert -- `echo rm`,
# `grep rm file`. Quoting it (`grep 'rm' file`) is the fix, and the deny
# message says so.
#
# Refs: #290 (this hook), #287 / #288 (same defect class, same batch).

set -uo pipefail

# --------------------------------------------------------------------------
# THE PROCESS-LEVEL DEFAULT
#
# Everything below this block computes a verdict. This block is what happens
# when it cannot compute one. A hook that emits nothing is read downstream as
# "this guard had no opinion", and the tool call proceeds -- so "the guard
# crashed" and "the guard approved" are the same event to everything that
# reads the guard. That is the fail-open default this hook exists to remove,
# reappearing one level up, inside the guard. It is closed the same way: a
# verdict leaves this process no matter how the process ends.
#
# RMG_FINISHED is set only by the path that ran to completion -- including
# the deliberate silence for a command with no `rm` in it. Any other ending
# (an unbound variable, an exit, a signal) leaves it 0, and the trap turns
# that into a deny. Two crashes the trap cannot cover, named so they are not
# mistaken for coverage: a syntax error in this file, where the file never
# runs at all (bash exits 2, which Claude Code already reads as "block"), and
# SIGKILL, which no handler sees.
# --------------------------------------------------------------------------

RMG_FINISHED=0
RMG_VERDICT_SENT=0

readonly RMG_CRASH_JSON='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"The rm guard exited before it reached a verdict; its stderr says why. A guard that cannot answer must not be read as permission, so this deletion is refused. Run it yourself, or use trash-put (/safe-delete), which is recoverable."}}'

# rmg_exit_guard -- the last thing this process does. Emits a deny unless a
# verdict was already emitted, and exits 0 either way, because Claude Code
# parses hook stdout as a verdict only on exit 0: a non-zero exit carrying
# perfect JSON is reported as a hook error and the call proceeds.
rmg_exit_guard() {
  local rc=$?
  if (( RMG_FINISHED )); then
    exit "${rc}"
  fi
  # Set before printing, not after: this function also runs on the EXIT that
  # follows a signal it just handled, and two verdicts on stdout parse as
  # neither.
  if (( ! RMG_VERDICT_SENT )); then
    RMG_VERDICT_SENT=1
    printf '%s\n' "${RMG_CRASH_JSON}"
  fi
  exit 0
}
trap rmg_exit_guard EXIT HUP INT TERM

# Nesting budget for `bash -c '... bash -c "..." ...'`.
readonly RMG_MAX_DEPTH=2

# Byte ceiling for the lexer (see WHAT THIS DELIBERATELY DOES NOT COVER).
readonly RMG_MAX_COMMAND=65536

# Short options a shell takes with NO argument of its own. `c` is handled
# separately; every other character in a bundle must be on this list, or the
# guard cannot say which word is the payload (`-o` takes one, so `-o errexit
# -c ...` would have the guard reading `errexit` as the payload). Anything
# absent -- `o`, `O`, `s`, and whatever a later bash adds -- denies.
readonly RMG_SH_NOARG_FLAGS='abBeEfhHiklmnprtTuvxC'

# The same list for long options, space-delimited on both sides so a
# membership test cannot match a prefix. `--rcfile` / `--init-file` take an
# argument and are deliberately absent.
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
rmg_end_word() {
  local val bad name value
  if (( RMG_WOPEN )); then
    if (( RMG_SKIP )); then
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
          if [[ -n "${bad}" ]]; then
            RMG_VARS["${name}"]=''
            RMG_VARS_BAD["${name}"]="${bad}"
          else
            RMG_VARS["${name}"]="${value}"
            unset "RMG_VARS_BAD[${name}]"
          fi
        elif [[ "${val}" != export && "${val}" != declare && \
                "${val}" != typeset && "${val}" != local && \
                "${val}" != readonly ]]; then
          RMG_ASSIGN_CTX=0
        fi
      fi
    fi
  fi
  RMG_W=''
  RMG_WBAD=''
  RMG_WQ=0
  RMG_WOPEN=0
}

# rmg_push_sep <text> -- close the in-progress word and push a separator.
rmg_push_sep() {
  rmg_end_word
  RMG_TOK_VAL+=("$1")
  RMG_TOK_KIND+=("sep")
  RMG_TOK_BAD+=("")
  RMG_TOK_Q+=(0)
  RMG_ASSIGN_CTX=1
}

# rmg_expand_var <name> -- append <name>'s value to the in-progress word,
# preferring an assignment seen earlier in this command over the hook's own
# environment. Neither -> the word is unresolvable.
rmg_expand_var() {
  local name="$1"
  if [[ -n "${RMG_VARS[${name}]+set}" ]]; then
    if [[ -n "${RMG_VARS_BAD[${name}]+set}" ]]; then
      RMG_WBAD="\$${name} was assigned a value this guard cannot resolve"
    else
      RMG_W+="${RMG_VARS[${name}]}"
    fi
    return 0
  fi
  if [[ -v "${name}" ]]; then
    RMG_W+="${!name}"
    return 0
  fi
  RMG_WBAD="\$${name} is set neither in the command nor in the environment"
}

# rmg_read_dollar <string> <index> -- consume the `$...` expansion at
# <index>, appending to the in-progress word. Sets RMG_NEXT to the index
# just past it. Returns 1 for command / arithmetic substitution, which the
# caller turns into a whole-command parse failure.
rmg_read_dollar() {
  local s="$1" i="$2"
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
        rmg_expand_var "${body}"
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
      rmg_expand_var "${name}"
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
          rmg_read_dollar "${s}" "${i}" || return 1
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
        rmg_read_dollar "${s}" "${i}" || return 1
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
            # `<<<` here-string: its word is data, not an operand.
            (( i++ )); RMG_SKIP=1; continue
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
  return 0
}

# --------------------------------------------------------------------------
# Target resolution
# --------------------------------------------------------------------------

# rmg_nearest_existing_dir <path> -- print the physical directory that
# decides for <path>: <path> itself when it exists, else its nearest
# existing ancestor. Returns 1 when something exists there but cannot be
# entered (a file where a directory must be, an unsearchable directory),
# because that is an unknown target rather than an absent one.
rmg_nearest_existing_dir() {
  local d="$1" out
  while :; do
    if [[ -e "${d}" ]]; then
      out="$(cd -P -- "${d}" 2>/dev/null && pwd -P)" || return 1
      [[ -z "${out}" ]] && return 1
      printf '%s\n' "${out}"
      return 0
    fi
    [[ "${d}" == "/" ]] && return 1
    d="${d%/*}"
    [[ -z "${d}" ]] && d="/"
  done
}

# rmg_in_git_tree <dir> -- 0 inside a working tree, 1 definitively outside,
# 2 unknown (which the caller fails closed on).
rmg_in_git_tree() {
  local dir="$1" out rc
  if [[ -n "${RMG_GIT_CACHE[${dir}]+set}" ]]; then
    return "${RMG_GIT_CACHE[${dir}]}"
  fi
  out="$(LC_ALL=C git -c safe.directory='*' -C "${dir}" \
    rev-parse --show-toplevel 2>&1)"
  rc=$?
  if (( rc == 0 )); then
    if [[ -n "${out}" ]]; then rc=0; else rc=2; fi
  elif [[ "${out}" == *"not a git repository"* ]]; then
    rc=1
  else
    rc=2
  fi
  RMG_GIT_CACHE["${dir}"]="${rc}"
  return "${rc}"
}

# rmg_operand_verdict <operand> -- 0 when the operand resolves outside every
# git working tree, 2 (with RMG_REASON set) otherwise.
rmg_operand_verdict() {
  local operand="$1" abs dir probe decider

  if [[ -z "${operand}" ]]; then
    RMG_REASON="rm was given an empty operand, so its target is unknown"
    return 2
  fi

  if [[ "${operand}" == /* ]]; then
    abs="${operand}"
  else
    if [[ -z "${RMG_CWD_PHYS}" ]]; then
      RMG_REASON="rm operand '${operand}' is relative and the invocation cwd (${RMG_CWD:-unset}) does not resolve, so its target is unknown"
      return 2
    fi
    abs="${RMG_CWD_PHYS}/${operand}"
  fi

  while [[ "${abs}" == */ && "${abs}" != "/" ]]; do abs="${abs%/}"; done

  if [[ "${abs}" == "/" ]]; then
    RMG_REASON="rm operand '${operand}' resolves to the filesystem root, which is never a routine deletion"
    return 2
  fi

  dir="${abs%/*}"
  [[ -z "${dir}" ]] && dir="/"

  # An existing real directory is judged as itself, so deleting a repo root
  # is inside the tree it would delete. A symlink is judged where the link
  # lives, because rm removes the link and not its target.
  if [[ -d "${abs}" && ! -L "${abs}" ]]; then
    probe="${abs}"
  else
    probe="${dir}"
  fi

  if ! decider="$(rmg_nearest_existing_dir "${probe}")"; then
    RMG_REASON="rm operand '${operand}' has no resolvable directory (${probe}), and an unresolvable target is an unknown target"
    return 2
  fi

  rmg_in_git_tree "${decider}"
  case "$?" in
    0)
      RMG_REASON="rm operand '${operand}' resolves to ${abs}, inside the git working tree at ${decider}. A deletion inside a working tree needs a human: run it yourself, or use 'trash-put' (/safe-delete) or 'git rm', which are recoverable"
      return 2
      ;;
    1) return 0 ;;
    *)
      RMG_REASON="git could not say whether ${decider} is a working tree, and an unanswered question is an unknown target"
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

# rmg_loose_rm <token index...> -- 2 when an unquoted literal `rm` appears
# among words this hook cannot place, 0 otherwise.
rmg_loose_rm() {
  local t
  for t in "$@"; do
    if [[ "${RMG_TOK_VAL[t]}" == "rm" && "${RMG_TOK_Q[t]}" == 0 ]]; then
      RMG_REASON="'rm' appears as an argument to another command, an invocation form this guard does not model (xargs / sudo / find -exec / a wrapper), so its targets are unknown. If the word is inert, quote it"
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
    # `--` ends options, and a word that is not an option ends them too:
    # from here on this is a script name and its arguments, not a payload.
    if [[ "${w}" == "--" || "${w}" != -?* ]]; then
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
      RMG_PAYLOAD="${RMG_TOK_VAL[${idx[j+1]}]}"
      return 0
    fi
    (( j++ ))
  done
  return 1
}

# rmg_simple_command <depth> <token index...> -- classify one simple
# command. 0 no rm, 1 rm and every target is outside, 2 deny.
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
    git)
      # Out of scope by decision, not by omission: see WHAT THIS
      # DELIBERATELY DOES NOT COVER.
      return 0
      ;;
    cd)
      # `cd <dir> && rm <relative>` deletes in <dir>, not in the invocation
      # cwd. Track it, and treat a cd we cannot follow as an unknown cwd, so
      # every later relative operand denies instead of resolving somewhere
      # the command will not be.
      rmg_apply_cd "${idx[@]:k+1}"
      return 0
      ;;
    pushd|popd)
      RMG_CWD_PHYS=''
      return 0
      ;;
    bash|sh|dash|zsh)
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
      rmg_loose_rm "${idx[@]:k+1}" || return 2
      return 0
      ;;
    *)
      rmg_loose_rm "${idx[@]:k+1}" || return 2
      return 0
      ;;
  esac
}

# rmg_walk <depth> -- split the token stream into simple commands and
# classify each. 0 no rm, 1 rm and every target is outside, 2 deny.
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
# 0 no rm, 1 allow, 2 deny (RMG_REASON set).
rmg_analyse() {
  local cmd="$1" depth="$2"
  # Per-frame parser state; see the Lexer note above on dynamic scoping.
  local -a RMG_TOK_VAL=() RMG_TOK_KIND=() RMG_TOK_BAD=() RMG_TOK_Q=()
  local -a RMG_HD=() RMG_HDS=()
  local RMG_W='' RMG_WBAD='' RMG_WQ=0 RMG_WOPEN=0 RMG_SKIP=0
  local RMG_NEXT=0 RMG_HD_DELIM='' RMG_ASSIGN_CTX=1

  if (( ${#cmd} > RMG_MAX_COMMAND )); then
    RMG_REASON="the command is longer than ${RMG_MAX_COMMAND} bytes, which this guard does not parse, so its rm targets are unknown"
    return 2
  fi
  if ! rmg_tokenize "${cmd}"; then
    RMG_REASON="the command uses a construct this guard does not parse (command substitution, a subshell, or an unterminated quote), so its rm targets are unknown"
    return 2
  fi
  rmg_walk "${depth}"
}

# rmg_analyse_nested <payload> <depth> -- analyse a `bash -c` payload with a
# fresh variable map: only the environment crosses the boundary.
rmg_analyse_nested() {
  local -A RMG_VARS=() RMG_VARS_BAD=()
  local RMG_CWD_PHYS="${RMG_CWD_PHYS}"
  rmg_analyse "$1" "$2"
}

# --------------------------------------------------------------------------

# rmg_mentions_rm <command> -- cheap gate so a command with no `rm` word in
# it is never parsed, and so a parse failure can safely mean DENY.
rmg_mentions_rm() {
  [[ "$1" =~ (^|[^A-Za-z0-9_.-])rm([^A-Za-z0-9_.-]|$) ]]
}

# rmg_emit <decision> <reason> -- print one verdict, or return 1 having
# printed nothing. The JSON is built whole before any of it is written, so a
# failure inside jq cannot leave half a verdict on stdout for the caller to
# parse; returning 1 hands the answer to rmg_exit_guard, which denies.
rmg_emit() {
  local out
  out="$(jq -n --arg d "$1" --arg r "$2" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $d,
      permissionDecisionReason: $r
    }
  }')" || return 1
  [[ -n "${out}" ]] || return 1
  printf '%s\n' "${out}"
  RMG_VERDICT_SENT=1
}

# rmg_run -- read the hook input, decide, emit. Everything that can fail
# lives here; main() exists only to record that it did not.
rmg_run() {
  local input cmd rc
  # Parser + verdict state, local to main so nothing leaks between hook runs.
  local RMG_CWD='' RMG_CWD_PHYS='' RMG_REASON='' RMG_PAYLOAD=''
  local -A RMG_VARS=() RMG_VARS_BAD=() RMG_GIT_CACHE=()

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
    1) rmg_emit allow "every rm target resolves outside any git working tree" || exit 1 ;;
    *) rmg_emit deny "${RMG_REASON}" || exit 1 ;;
  esac
  return 0
}

# main -- the only place RMG_FINISHED is set, and it is set after rmg_run
# returns, so every other way out of this process lands in rmg_exit_guard.
main() {
  rmg_run
  RMG_FINISHED=1
}

main "$@"
