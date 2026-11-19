#!/usr/bin/env bash
# deny_ai_attribution_commit.sh -- Claude Code PreToolUse hook (matcher: Bash).
#
# Denies a `git ... commit` or `gh pr merge` whose message carries an AI
# attribution marker, before it runs (refs base#1988). Scans the command text,
# any -F / --file / --body-file file, and for a `gh pr merge` without a body
# flag the PR body from `gh pr view`. The command is tokenised the way the
# shell reads it (python shlex, as remind_no_chinese_in_git_artifacts.sh
# does), so quoted words stay whole, `git -C <dir>` moves where -F resolves,
# and `git log --grep '... commit ...'` is not a commit.
# Matcher shared with the commit-msg hook (lib/attribution_marker.sh).
# Catches honest mistakes, not deliberate evasion; the CI check (base#1989) is
# the backstop. Every internal error fails open (silent exit 0).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../scripts/lib/attribution_marker.sh
source "${HOOK_DIR}/../scripts/lib/attribution_marker.sh" 2>/dev/null || exit 0

# plan <cmd> <cwd> -- one \x1f-separated line per thing to scan: "G" when a
# commit or merge runs, "F<path>" for a message file, "P<n><repo>" for a
# `gh pr merge` whose stored PR body is the message (<n> empty: current PR).
PLAN_PY='
import os, re, shlex, sys
cmd, cwd = sys.argv[1], sys.argv[2] or "."
HEREDOC = re.compile(r"(?:^|[^<])<<-?[ \t]*[\"\x27]?([A-Za-z_][A-Za-z0-9_]*)")
GIT_VAL = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix"}
GH_VAL = {"-t", "--subject", "-b", "--body", "-F", "--body-file", "-R", "--repo", "-A", "--author-email", "--match-head-commit"}
FILE = {"-F", "--file", "--body-file"}
out, kept, stop = [], [], None
for line in cmd.split("\n"):
    if stop is not None:
        stop = None if line.strip() == stop else stop
        continue
    kept.append(line)
    m = HEREDOC.search(line)
    stop = m.group(1) if m else None
for line in "\n".join(kept).replace("\\\n", " ").split("\n"):
    try:
        lex = shlex.shlex(line, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        toks = line.split()
    words = []
    for t in toks + [";"]:
        if t and all(c in "();<>|&" for c in t):
            argv = words[next((i for i, w in enumerate(words) if not re.match(r"^[A-Za-z_]\w*=", w)), len(words)):]
            words = []
            base, i = cwd, 1
            if argv[:1] == ["git"]:
                while i < len(argv) and argv[i].startswith("-"):
                    if argv[i] == "-C" and i + 1 < len(argv):
                        base = os.path.join(base, argv[i + 1])
                    i += 2 if argv[i] in GIT_VAL else 1
                if argv[i:i + 1] != ["commit"]:
                    continue
            elif argv[:3] == ["gh", "pr", "merge"]:
                i = 3
            else:
                continue
            out.append("G")
            rest, n, repo, body = argv[i + 1:] if argv[0] == "git" else argv[3:], "", "", False
            j = 0
            while j < len(rest):
                w, v = rest[j], rest[j + 1] if j + 1 < len(rest) else ""
                k, eq, val = w.partition("=")
                if eq and k in FILE | GH_VAL:
                    w, v = k, val
                elif w in FILE or (argv[0] == "gh" and w in GH_VAL):
                    j += 1
                elif argv[0] == "gh" and not w.startswith("-") and not n:
                    n = w
                if w in FILE and v and v != "-":
                    out.append("F\x1f" + os.path.join(base, v))
                body |= w in ("-b", "--body", "-F", "--body-file")
                repo = v if w in ("-R", "--repo") else repo
                j += 1
            if argv[0] == "gh" and not body:
                out.append("P\x1f%s\x1f%s" % (n, repo))
        else:
            words.append(t)
print("\n".join(out))
'

# pr_body <n> <repo> <cwd> -- the stored body of PR <n> (current branch PR when
# empty), looked up from <cwd>; nothing when the lookup fails.
pr_body() {
  local body
  body="$(cd "${3:-.}" && timeout 10 gh pr view ${1:+"$1"} ${2:+--repo "$2"} \
    --json body -q .body 2>/dev/null)" || return 0
  printf '%s\n' "${body}"
}

main() {
  local input cmd cwd plan kind a b match extra=""
  input="$(cat)"
  cmd="$(jq -r '.tool_input.command // empty' <<< "${input}" 2>/dev/null)" || return 0
  [[ "${cmd}" == *commit* || "${cmd}" == *merge* ]] || return 0
  cwd="$(jq -r '.cwd // empty' <<< "${input}" 2>/dev/null)" || cwd=""
  plan="$(python3 -c "${PLAN_PY}" "${cmd}" "${cwd}" 2>/dev/null)" || return 0
  [[ -n "${plan}" ]] || return 0
  while IFS=$'\x1f' read -r kind a b; do
    case "${kind}" in
      F) [[ -f "${a}" ]] && extra+="$(cat -- "${a}" 2>/dev/null)"$'\n' ;;
      P) extra+="$(pr_body "${a}" "${b}" "${cwd}")"$'\n' ;;
    esac
  done <<< "${plan}"
  match="$(printf '%s\n%s' "${cmd}" "${extra}" | attribution_marker_find)" || return 0
  local msg="AI attribution gate (base#1988): the commit message carries an AI attribution marker: '${match}'. Remove it and commit again."
  jq -n --arg m "${msg}" '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PreToolUse",
    permissionDecision: "deny", permissionDecisionReason: $m}}'
  return 0
}

main "$@"
