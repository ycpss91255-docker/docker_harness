#!/usr/bin/env bash
# log-allow:script -- pure parsing library, emits nothing.
#
# gh-command.sh -- the shared "which command is this, actually" parser for
# hooks that inspect a Bash command string for a `gh` invocation.
#
# WHY THIS IS ONE FILE: #255, #276 and #283 were three reports of a single
# defect -- a hook reading DATA as SYNTAX. A `gh` inside a heredoc body, a
# `gh` inside another command's quoted argument, a flag on the far side of
# a `&&`, a flag on the continuation line of a folded command: each one
# produced either a false deny or a silent miss. The rule that came out of
# it (CONTEXT.md section 15) is that a hook must establish *what the
# command is* before deciding *what it contains*, and this library is the
# one place that decision is made. A fourth ad-hoc copy would drift.
#
# Extracted verbatim from enforce_gh_body_file.sh, which now sources it
# (refs #294, where a second hook needed the same answer).
#
# Callers: .claude/hooks/enforce_gh_body_file.sh,
#          .claude/hooks/enforce_ready_for_agent.sh

# fold_continuations <cmd> -- collapse backslash-newline into a space.
# A trailing backslash is a line continuation INSIDE one command, so the
# newline after it is not a command boundary. Without this a multi-line
# invocation is cut at line 1 and every flag below it (a --body-file, a
# --label, an --add-label) is invisible to every rule -- a false deny on
# a valid command (refs #283).
fold_continuations() {
  printf '%s' "${1//\\$'\n'/ }"
}

# strip_heredocs <cmd> -- drop every heredoc BODY (and its terminator),
# keeping the line that opens it. Heredoc content is data the command
# writes somewhere, not commands being run: a body line that happens to
# start with `gh` is prose, and reading it as the invocation is the same
# data-as-syntax mistake as #255 (refs #283). `<<<` herestrings are not
# heredocs and are left alone.
strip_heredocs() {
  local line trimmed out="" delim="" in_body=0
  while IFS= read -r line; do
    if (( in_body )); then
      trimmed="${line#"${line%%[![:space:]]*}"}"
      [[ "${trimmed}" == "${delim}" ]] && in_body=0
      continue
    fi
    out+="${line}"$'\n'
    if [[ "${line}" =~ (^|[^<])\<\<-?[[:space:]]*[\"\']?([A-Za-z_][A-Za-z0-9_]*) ]]; then
      delim="${BASH_REMATCH[2]}"
      in_body=1
    fi
  done <<< "$1"
  printf '%s' "${out}"
}

# gh_segment <cmd> -- the segment of <cmd> whose COMMAND WORD is `gh`:
# split <cmd> on the shell separators (&&, ||, |, ;, newline) and return
# the first piece whose first token is `gh`. Returns 1 when no segment
# actually runs gh -- a `gh ...` merely quoted inside another program's
# argument is a string, not an invocation.
#
# ALL flag detection must scope to this segment, else a flag belonging to
# a different program in a chained command (a trailing `echo "... --body
# ..."`, `python3 -c`, `git log -S`) false-triggers the verdict (refs
# #255). Naive w.r.t. quotes (a separator inside a quoted body truncates
# the segment) -- the goal is cross-command isolation, not a full shell
# parser; the truncation only affects the flag VALUE, never the presence
# of the gh subcommand + flag.
gh_segment() {
  local cmd seg
  cmd="$(strip_heredocs "$1")"
  cmd="$(fold_continuations "${cmd}")"
  cmd="${cmd//&&/$'\n'}"
  cmd="${cmd//||/$'\n'}"
  cmd="${cmd//|/$'\n'}"
  cmd="${cmd//;/$'\n'}"
  while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"   # ltrim leading whitespace
    if [[ "${seg}" =~ ^gh[[:space:]] ]]; then
      printf '%s' "${seg}"
      return 0
    fi
  done <<< "${cmd}"
  return 1
}

# gh_mentions_gh <cmd> -- cheap pre-filter: does <cmd> contain a `gh`
# token at all? Lets a caller return early on the overwhelming majority
# of commands before paying for the segment split.
gh_mentions_gh() {
  printf '%s' "$1" | grep -qE '(^|[[:space:]&|;])gh[[:space:]]'
}

# gh_subcommand <seg> -- print "<noun> <verb>" (e.g. `issue edit`) for a
# gh segment, empty when it is neither an issue nor a pr subcommand.
gh_subcommand() {
  local seg="$1"
  if [[ "${seg}" =~ gh[[:space:]]+(issue|pr)[[:space:]]+([a-z]+) ]]; then
    printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
}

# gh_repo_flag <seg> -- print the value of `-R` / `--repo` on the
# segment, empty when absent (gh then resolves the repo from cwd).
gh_repo_flag() {
  local seg="$1"
  if [[ "${seg}" =~ (^|[[:space:]])(-R|--repo)[[:space:]]+\"([^\"]+)\" ]]; then
    printf '%s' "${BASH_REMATCH[3]}"
    return 0
  fi
  if [[ "${seg}" =~ (^|[[:space:]])(-R|--repo)[[:space:]]+\'([^\']+)\' ]]; then
    printf '%s' "${BASH_REMATCH[3]}"
    return 0
  fi
  if [[ "${seg}" =~ (^|[[:space:]])(-R|--repo)[[:space:]=]+([^[:space:]\"\']+) ]]; then
    printf '%s' "${BASH_REMATCH[3]}"
    return 0
  fi
  printf ''
}

# gh_flag_value <seg> <long-flag> -- print the value of `--<flag> V`,
# `--<flag>="V"` etc. on the segment; return 1 when the flag is absent.
# Quoted forms are tried first so a quoted value containing spaces is
# returned whole.
gh_flag_value() {
  local seg="$1" flag="$2"
  if [[ "${seg}" =~ ${flag}[[:space:]]+\"([^\"]*)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${seg}" =~ ${flag}[[:space:]]+\'([^\']*)\' ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${seg}" =~ ${flag}=\"([^\"]*)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${seg}" =~ ${flag}=\'([^\']*)\' ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${seg}" =~ ${flag}[[:space:]=]+([^[:space:]]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}
