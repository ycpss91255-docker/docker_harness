# ADR-00000015: rm safety lives in the permission ask, not in a hook parser

- **Date:** 2026-08-31
- **Status:** Accepted
- **Relates to:** issue #290 (the hook and this decision), #287 / #288
  (the same defect class in the same batch), ADR-00000006 (worktrees --
  the reason so many directories on this machine are working trees)

## Context

The property we want is not in dispute:

> A deletion that would remove any part of any git working tree needs a
> human; a deletion that would not does not.

It is a statement about where bytes live. `permissions.ask: Bash(rm:*)`
plus a growing list of `Bash(rm ...)` allow rules expressed it as literal
prefix matches over the command STRING, and that list reached 480 entries
while being incomplete in one direction (the next caller-chosen variable
name always missed) and unsound in the other (`rm -rf /tmp/../etc` starts
with the allowed prefix `rm -rf /tmp/`).

#290 proposed the obvious fix: compute the property in a `PreToolUse`
hook -- resolve every `rm` operand to an absolute physical path, ask git
one question per target, DENY when any target is inside a working tree --
and then delete both the allow list and the blanket ask, "because leaving
them beside a working hook would leave two rules disagreeing about the
same question."

That was built. It was reviewed three times. Each review found shapes the
parser did not model, and proved each one by actually deleting a tracked
file out of a real working tree:

| Command | What the guard did |
|---|---|
| `bash <<EOF` / `rm -rf <repo>/src` / `EOF` | skipped the body as data |
| `sh <<< 'rm -rf <repo>/src'` | discarded the here-string word |
| `bash -c -- 'rm -rf <repo>/src'` | analysed the payload `--` |
| `builtin cd <repo> && rm -rf src` | kept a stale cwd and said ALLOW |
| `r"m" -rf <repo>/src` | its text prefilter never woke up |

Round two had closed five different bypasses just as carefully. The
pattern is not "the author missed five cases". It is that a command
string is not a set of paths until a shell expands it, and bash's
spellings are not finite, so no parser over the string can be the thing
that decides.

The compounding error was structural rather than parsing: with the
blanket ask removed, the hook's SILENCE meant the deletion proceeded. So
every parser miss, every crash, a missing `jq`, and the 10s hook timeout
were all read as consent. The guard's failure mode was the exact
fail-open default the issue set out to remove, reappearing one level up
inside the guard.

## Decision

**Keep `permissions.ask: Bash(rm:*)` as the guard. Demote the hook to an
auto-allow that may only remove a prompt or add one.**

`.claude/hooks/auto_allow_rm_outside_git_tree.sh` emits exactly three
things:

- `allow` -- it resolved every target of every `rm` in the command and
  every one is outside every working tree, and holds none;
- `ask` -- it reached a definite reason a human is needed, and names the
  resolved target and the tree's root;
- nothing -- anything else.

It never emits `deny`; refusal stays the permission system's to give, and
"needs a human" is what `ask` means.

The five bypasses are then dead by construction rather than by five more
branches: none of them can produce an `allow`, and the worst any of them
can do is leave the hook silent, which is the human. The same sentence
covers a construct the lexer refuses, a missing `jq`, an unbound
variable, a signal, the hook timeout, and a command the cheap text gate
never woke up for. The EXIT trap that used to manufacture a deny is gone,
because there is no longer a default worth writing.

Three rules do the remaining work, and each is a rule rather than a case:

1. Text the lexer discards as DATA is still text a shell may execute, so
   an `rm` token in a heredoc body or a here-string word makes the whole
   command un-allowable.
2. A word the guard cannot PLACE is never analysed as if it could be --
   `bash -c --` says so rather than reading the `--`, because real bash
   discards it and runs the next word.
3. A simple command the guard does not model may have moved the shell, so
   it blanks the tracked cwd. That covers `builtin cd`, `command cd`,
   `eval`, a shell function and whatever comes next, without a list of
   builtins to keep up with. It costs a prompt on
   `mkdir -p x && rm -rf x/y`.

## What this deliberately does NOT close

The ask rule is itself a match on the command text, performed by Claude
Code. `rm ...` matches it; `/bin/rm -rf <repo>/x` and
`X=r; ${X}m -rf <repo>/x` do not, and a PreToolUse hook cannot fix that
from here -- it may add a prompt or remove one, never make the tool call
not happen. For the first two the hook is the only thing that speaks: it
lexes `/bin/rm` and `r"m"` correctly and asks. That is a courtesy, not a
guarantee, and the header says so in those words.

## Alternatives considered

### A shim named `rm`, early on the agent shell's PATH

Ask the question AFTER expansion, where there is no quoting left to lose:
a shim reads its own argv, resolves each operand and refuses the ones
inside a working tree. Every bypass above stops existing rather than
stops working, because the shell has already done the parsing.

Measured on this machine (Claude Code 2.1.251), it is installable:

- settings.json `env` DOES reach Bash tool calls (a probe variable set
  there was visible to `printenv` inside a Bash call);
- `env` values are NOT interpolated -- `"/rmg/shim:${PATH}"` arrived
  verbatim, `${PATH}` unexpanded;
- `CLAUDE_CODE_SHELL_PREFIX` DOES wrap every Bash tool call: the wrapper
  is spawned with the full command string as one argument, so it can
  prepend a directory to `PATH` and hand the string to a shell.

It is not adopted here because of what it costs, not because it does not
work:

- no interpolation means the wrapper path is absolute and
  machine-specific, so it has to come from an untracked
  `settings.local.json` that a fresh clone of this repo does not have --
  the guard would be absent by default across the org;
- a shim can only refuse, never ask, so every in-tree deletion becomes a
  hard failure with no in-loop approval -- a workflow change, not an
  implementation detail;
- a wrapper that misbehaves takes every Bash call in the session with it
  (a wrapper that ran `exec "$@"` instead of `exec bash -c "$1"` made
  every command in the probe session exit 127);
- `/bin/rm`, `busybox rm`, `perl -e unlink` and `find -delete` walk past
  a PATH shim anyway, so it is an accident guard, not a guarantee -- a
  better one than this hook, but the same KIND of thing.

The shim is the right shape for a guarantee and is worth doing on its own
issue, with the user deciding the three trade-offs above. It is not worth
shipping half of.

### Keep the hook as the guard and model five more shapes

Rejected. Two rounds of evidence say the next reviewer finds the sixth.

### Delete the hook and keep only the ask

Sound, and the friction is the reason #290 was filed: the agent's own
scratch deletions (`rm -rf "$TMPDIR/mut957"`) prompt on every call. The
hook earns its place by removing exactly those prompts, and it can do
that safely because its failure direction is now a prompt.

## Consequences

- Silence from the hook is safe, so no code path in it needs a default.
- A prompt, never a refusal, is the cost of everything it cannot place --
  including inert mentions (`echo rm`, `grep 'rm' file`, `git rm`).
- `git` lost its blanket skip: `git submodule foreach 'rm -rf ...'`,
  `git bisect run rm ...` and `git rebase -x 'rm ...'` were invisible
  while `git rm` was the reason given for skipping.
- The untracked machine-local `settings.local.json` still carries the 480
  dead `Bash(rm ...)` allow rules, and they now matter again: an allow
  rule beats the ask whenever the hook is silent. Pruning them is a local
  step for that file's owner (`jq '.permissions.allow |= map(select(
  startswith("Bash(rm ") | not))'`).
- If `permissions.ask: Bash(rm:*)` is ever removed from
  `.claude/settings.json`, this hook becomes fail-open again. A spec
  stanza asserts that line is present, so removing it fails the gate.
