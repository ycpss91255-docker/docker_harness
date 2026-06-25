---
name: skillification-candidates
description: At task wrap-up, surface candidates to promote into a `.claude/scripts/<name>.sh` / slash command / skill instead of retyping. Use when the `remind_skillification_candidates.sh` Stop hook nudges, or after a task with something you'll redo soon.
---

# skillification-candidates

CLAUDE.md says: "at task wrap-up, list the tools/scripts/workflows that produced or evolved this session that you will redo next time." The paired `remind_skillification_candidates.sh` Stop hook fires when transcript signals show a candidate exists; this skill is the rubric for what counts and how to propose it.

## When to use

- A PR just merged or a multi-step task closed out and you about to declare done.
- The `remind_skillification_candidates.sh` Stop hook surfaced its reminder.
- During the task you noticed an `/tmp/foo.sh` you wrote and ran three times -- raise it now before the session compacts and the path goes with it.

## The four candidate categories

| # | Category | Signal you saw it | Where it should live |
|---|---|---|---|
| 1 | **`/tmp/*.sh` re-use** | You wrote a one-off in `/tmp/` and invoked it 3+ times this session | Promote to `.claude/scripts/<name>.sh` with named flags (`--branch`, `--limit`, ...) -- atomic args keep the parser from falling back; permanent path survives compact |
| 2 | **Repeated parser-fallback Bash** | You typed the same 3+ complex one-liner that pushes the Claude Code Bash AST parser to ask the user (heredoc redirect, `${var%:*}`, `<<<` herestring, `cd path && ...`, `(cd dir && ...)`) | Move the body into a permanent script and call it with atomic args -- same as category 1 above; the parser-warning section of CLAUDE.md lists the patterns |
| 3 | **Slash-command gap** | You ran a 4+ step ritual by hand (open issue / clone / branch / patch / push / PR-create / CI-wait / merge / cleanup) that no existing `/<cmd>` covers | Sketch a new `.claude/commands/<name>.md` and propose it as a follow-up. Existing `/pr` / `/release` / `/batch-base-upgrade` / `/issue-fix` are the model shape |
| 4 | **Bug or gap in an existing skill** | While following a skill, you found that one step is wrong / missing a flag / does not handle a case (e.g. an extra `--check-filter` form needed by a new repo type) | One-line patch to the skill body, or a follow-up issue with the exact transcript line that exposed the gap |

If none of the four fit, **do not invent a candidate**. The whole rule's value is that it captures real friction; noise erodes the user's trust in the reminder.

## How to phrase the offer

One short paragraph, framed as a question the user can redirect. Format:

```
Candidate: <name> -- <one-sentence what it does>
Shape: <slash command + script | permanent script | skill | issue>
Why: <signal from this session: X happened N times>
Priority: <high|med|low>
```

Examples:

- **Good:** "Candidate: `batch-pr-rebase.sh` — rebase a list of `<repo>:<pr>` against main, force-push with lease. Shape: permanent script. Why: hand-rebased 4 PRs this session, twice typing `git -C` chains. Priority: med."
- **Good:** "Candidate: `/issue-fix` accept `--label <label>` filter. Shape: slash-command flag. Why: I scoped to `tier-2` issues by hand-grepping the issue list. Priority: low."
- **Bad (unilateral):** "I added `batch-pr-rebase.sh` to `.claude/scripts/`." (You did not ask -- you decided.)
- **Bad (vague):** "Some things from this session could become scripts." (No name, no shape, no priority -- user cannot engage.)

## When NOT to offer

- Mid-implementation -- finish the task; raise candidates after.
- One-off operations -- truly single-use, won't repeat. Skill-ification has a fixed cost; one-off does not amortise it.
- The candidate is already covered -- there is an existing slash command / script / skill you forgot about. Search `.claude/commands/`, `.claude/scripts/`, and `.claude/skills/` first.
- The user already declined a similar proposal earlier this session -- the throttle marker in TMPDIR should already suppress this.

## Anti-patterns

- **Listing skillification candidates inside the feature implementation.** Save it for task wrap-up.
- **Treating the reminder as a command.** It's a one-shot nudge. If nothing fits the four categories, briefly say so or stay silent.
- **Long lists.** One or two real candidates beats five "maybe useful" ones.
- **Proposing without a name.** A nameless candidate cannot be approved or rejected -- always give the script / command / skill the name it would have.

## Hook integration

`.claude/hooks/remind_skillification_candidates.sh` (Stop hook) emits a one-shot reminder per session when any auto-detectable signal crosses its threshold:

- `/tmp/*.sh` re-use count >= `SKILLIFICATION_TMP_THRESHOLD` (default 3)
- parser-fallback pattern hits >= `SKILLIFICATION_PARSER_THRESHOLD` (default 3) -- counts Bash invocations matching the patterns from CLAUDE.md's "Bash 命令寫法的 parser 限制" table (heredoc redirect, `${var%:*}`, `<<<` herestring, `cd path && ...`)

Categories 3 (slash-command gap) and 4 (bug in existing skill) are NOT auto-detected -- they require semantic understanding that does not live in the hook. The skill body covers them so the agent surfaces them when it spots them.

Non-blocking; emits top-level `systemMessage` only. Disable per-session with `SKILLIFICATION_REMIND_DISABLE=1`.
