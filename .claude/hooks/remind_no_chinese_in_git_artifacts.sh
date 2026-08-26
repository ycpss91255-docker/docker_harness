#!/usr/bin/env bash
# remind_no_chinese_in_git_artifacts.sh — Claude Code PreToolUse hook
# (matcher: Bash, blocking).
#
# Purpose: keep git/GitHub artifacts (commit messages, PR + issue titles
# and bodies, comments) in English. README*.md and i18n files are the
# only places where CJK content is allowed; everything else must be
# ASCII/standard-English typography so commit history, PRs, and issues
# stay searchable, machine-readable, and reviewer-portable.
#
# Triggers (any one of these subcommands):
#   - git commit  with -m / --message / -F / --file
#   - gh pr   create | edit | comment   with --title / --body / --body-file
#   - gh issue create | edit | close | comment   with --title / --body / --body-file / --comment
#
# Detection ranges (each fires a deny):
#   U+4E00-U+9FFF   CJK Unified Ideographs              中文
#   U+3400-U+4DBF   CJK Ext-A                           rare ideographs
#   U+3000-U+303F   CJK Symbols & Punctuation           「」『』、。
#   U+FF00-U+FFEF   Halfwidth & Fullwidth Forms         ，！？fullwidth digits/letters
#
# Allowed (English typography uses these too):
#   U+2013/U+2014   en-dash / em-dash
#   U+2018-U+201D   smart quotes
#   U+2026          ellipsis
#
# Action: returns hookSpecificOutput.permissionDecision = "deny" with a
# reason naming the offending character + its location, so Claude rewrites
# in English on the spot and no force-push / amend is needed afterwards.
#
# File-arg handling: -F / --file / --body-file values are read from disk
# and scanned. Path-based skip — i18n and README*.md files exempt:
#   *README*.md, *.zh-TW.md, *.zh-CN.md, *.ja.md, *.ko.md
#   *i18n*, *.po, *.pot, *.mo

set -uo pipefail

# _scan_text <text> — print "<lineno>:<char>:<snippet>" + exit 1 on first
# disallowed CJK / fullwidth char in <text>; print nothing + exit 0 if
# clean. Text passed via argv (not stdin) because heredoc-supplied python
# programs consume stdin themselves.
_scan_text() {
  python3 -c '
import re, sys
PATTERN = re.compile(
    "["
    "一-鿿"   # CJK Unified Ideographs
    "㐀-䶿"   # CJK Ext-A
    "　-〿"   # CJK Symbols & Punctuation
    "＀-￯"   # Halfwidth/Fullwidth Forms
    "]"
)
text = sys.argv[1]
lines = text.splitlines() or [text]
for lineno, line in enumerate(lines, 1):
    m = PATTERN.search(line)
    if m:
        snippet = line.strip()[:80]
        print(f"{lineno}:{m.group(0)}:{snippet}")
        sys.exit(1)
sys.exit(0)
' "$1" 2>/dev/null
}

# _scan_file <path> — same output shape as _scan_text but reads <path>.
_scan_file() {
  python3 -c '
import re, sys
PATTERN = re.compile(
    "["
    "一-鿿"
    "㐀-䶿"
    "　-〿"
    "＀-￯"
    "]"
)
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for lineno, line in enumerate(f, 1):
            m = PATTERN.search(line)
            if m:
                snippet = line.rstrip()[:80]
                print(f"{lineno}:{m.group(0)}:{snippet}")
                sys.exit(1)
except OSError:
    pass
sys.exit(0)
' "$1" 2>/dev/null
}

# _is_exempt_path <path> — return 0 if README*-style or i18n / locale.
_is_exempt_path() {
  case "$1" in
    *README*.md|*.zh-TW.md|*.zh-CN.md|*.ja.md|*.ko.md) return 0 ;;
    *i18n*|*.po|*.pot|*.mo) return 0 ;;
  esac
  return 1
}

# _target_artifacts <cmd> — print a JSON array of the git artifacts this
# command actually WRITES, one object per artifact-producing command:
#   [{"text": "<the command's own tokens>", "files": ["<-F/--file/--body-file path>"]}]
#
# Scoping, not matching (refs #283, same lesson as #255): the rule applies
# to the artifact being written, never to a command that merely NAMES one.
# So the command string is tokenised (shlex, quote-aware) and split on the
# shell operators; only a segment whose own command WORD is `git commit` /
# `gh pr create|edit|comment` / `gh issue create|edit|close|comment`
# counts. A `git commit` sitting inside another command's quoted argument
# is one token of that command's argv, so it can never become a segment
# head -- and the CJK scan then sees only the target's own tokens, never
# the rest of the line.
_target_artifacts() {
  python3 -c '
import json, re, shlex, sys

ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# A doubled less-than plus a word opens a heredoc (the dash and quoted
# forms too); a tripled less-than is a herestring and opens nothing.
HEREDOC_OPEN = re.compile(r"(?:^|[^<])<<-?[ \t]*[\"\x27]?([A-Za-z_][A-Za-z0-9_]*)")
PUNCT = "();<>|&"
FILE_FLAGS = {"-F", "--file", "--body-file"}
GH_SUBCMDS = {
    "pr": {"create", "edit", "comment"},
    "issue": {"create", "edit", "close", "comment"},
}


def strip_heredocs(text):
    """text with every heredoc BODY removed, opening lines kept."""
    kept = []
    delimiter = None
    for line in text.split("\n"):
        if delimiter is not None:
            if line.strip() == delimiter:
                delimiter = None
            continue
        kept.append(line)
        match = HEREDOC_OPEN.search(line)
        if match:
            delimiter = match.group(1)
    return "\n".join(kept)


def fold_continuations(text):
    """text with backslash-continued newlines joined into one line.

    A newline separates two commands, but a newline after a trailing
    backslash is a continuation inside ONE command -- its flags, and its
    message, still belong to the command that started above.
    """
    return text.replace("\\\n", " ")


def split_commands(text):
    """Every simple command in text, as a token list."""
    out = []
    for line in fold_continuations(strip_heredocs(text)).split("\n"):
        if not line.strip():
            continue
        try:
            lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
            lexer.whitespace_split = True
            tokens = list(lexer)
        except ValueError:
            tokens = line.split()
        current = []
        for tok in tokens:
            if tok and all(ch in PUNCT for ch in tok):
                if current:
                    out.append(current)
                current = []
            else:
                current.append(tok)
        if current:
            out.append(current)
    return out


def as_target(tokens):
    """The argv of tokens if it writes a git artifact, else None."""
    i = 0
    while i < len(tokens) and (ENV_ASSIGN.match(tokens[i]) or tokens[i] == "sudo"):
        i += 1
    argv = tokens[i:]
    if not argv:
        return None
    if argv[0] == "git" and len(argv) > 1 and argv[1] == "commit":
        return argv
    if (
        argv[0] == "gh"
        and len(argv) > 2
        and argv[1] in GH_SUBCMDS
        and argv[2] in GH_SUBCMDS[argv[1]]
    ):
        return argv
    return None


def file_args(argv):
    out = []
    i = 0
    while i < len(argv):
        tok = argv[i]
        if tok in FILE_FLAGS and i + 1 < len(argv):
            out.append(argv[i + 1])
            i += 2
            continue
        flag, sep, value = tok.partition("=")
        if sep and flag in FILE_FLAGS:
            out.append(value)
        i += 1
    return out


artifacts = []
for tokens in split_commands(sys.argv[1]):
    argv = as_target(tokens)
    if argv:
        artifacts.append({"text": " ".join(argv), "files": file_args(argv)})
print(json.dumps(artifacts))
' "$1" 2>/dev/null
}

main() {
  local input cmd artifacts count idx text file_path file_hit
  input="$(cat)"
  cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"

  [[ -z "${cmd}" ]] && return 0

  artifacts="$(_target_artifacts "${cmd}")"
  [[ -z "${artifacts}" || "${artifacts}" == "[]" ]] && return 0
  count="$(printf '%s' "${artifacts}" | jq 'length' 2>/dev/null)"
  [[ -z "${count}" ]] && return 0

  local hit=""
  for (( idx = 0; idx < count; idx++ )); do
    # 1. Scan the artifact command's own tokens — covers -m "..." /
    #    --body "..." / --title "...", and nothing that belongs to
    #    another command on the same line.
    text="$(printf '%s' "${artifacts}" | jq -r ".[${idx}].text")"
    hit="$(_scan_text "${text}")"
    [[ -n "${hit}" ]] && break

    # 2. Scan its referenced files (-F / --file / --body-file). Skip
    #    exempt paths.
    while IFS= read -r file_path; do
      [[ -z "${file_path}" ]] && continue
      _is_exempt_path "${file_path}" && continue
      [[ -f "${file_path}" ]] || continue
      file_hit="$(_scan_file "${file_path}")"
      if [[ -n "${file_hit}" ]]; then
        hit="${file_path}:${file_hit}"
        break
      fi
    done < <(printf '%s' "${artifacts}" | jq -r ".[${idx}].files[]?")
    [[ -n "${hit}" ]] && break
  done

  [[ -z "${hit}" ]] && return 0

  local reason
  reason="CJK or fullwidth character detected in git/GitHub artifact (${hit}). CLAUDE.md i18n rule: only README*.md and i18n files may contain Chinese; commit messages, PR + issue titles + bodies + comments must be plain English. Rewrite in ASCII / standard English typography (em-dash and smart quotes remain allowed) and retry."

  jq -n --arg r "${reason}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
}

main "$@"
