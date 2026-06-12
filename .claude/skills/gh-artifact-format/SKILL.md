---
name: gh-artifact-format
description: Format rules for GitHub artifacts (issue title / body / close comment / PR / comment) plus the cross-ref keyword vocabulary for commit messages and PR bodies. Paired with the `enforce_gh_body_file.sh` PreToolUse hook that BLOCKS routing violations.
---

# gh-artifact-format

The companion hook `.claude/hooks/enforce_gh_body_file.sh` enforces the **routing** rules (long body must land in `/tmp/<name>.md` and pass `--body-file`, etc.). This skill describes the **content** rules: what shape an issue title takes, what sections a body has, when to use which close-comment tier, which cross-ref keyword auto-closes vs. only references.

The two pieces are paired: a violation of "use --body-file" is denied at hook time; a violation of "issue body should have a Problem section" is a skill-level lint that the human author / agent self-applies before writing the file.

Per #64 (the discussion that produced this skill), the 6 decision points landed:

1. Two-step close (`gh issue comment N --body-file X` then `gh issue close N [--reason ...]`) accepted -- no wrapper script.
2. SHORT_LIMIT = 80 chars, single line. Applies uniformly to: `gh pr review --body`, `gh pr comment --body`, `gh issue comment --body`, and trivial `gh issue close` follow-up (which is now the first half of the two-step).
3. Trivial close: short single-line body (<= 80 chars) can be inline on the `gh issue comment` step. Longer goes to `/tmp/issue-X-close.md`.
4. Hook: renamed `remind_use_body_file.sh` -> `enforce_gh_body_file.sh`, switched from non-blocking PostToolUse remind to blocking PreToolUse deny.
5. Single skill `gh-artifact-format` (this file) rather than per-artifact slash commands.
6. Cross-ref keywords: 5 keywords listed below.

## 1. Issue title

Shape: `type(scope): action`. <= 70 chars. Plain English, no CJK, verb-first.

| Type | Use for |
|---|---|
| `feat(<scope>)` | new functionality (slash command, hook, helper script, CI workflow) |
| `fix(<scope>)` | bug fix in shipped code |
| `docs(<scope>)` | doc changes (README, CLAUDE.md, CHANGELOG, TEST.md) |
| `refactor(<scope>)` | code reshape with no behaviour change |
| `chore(<scope>)` | release prep, version bumps, generated-file regeneration |
| `track(<scope>)` | "we should do X someday" / parking lot for future work |

Scope is one or two words pointing at the part of the repo: `commands`, `hook`, `skill`, `scripts`, `ci`, `settings`, `docker`, `template`, etc.

Examples:

- `feat(hook): check_no_stale_template_refs catches v0.25.0 rename drift at Edit time`
- `fix(settings): exclude .claude/scripts/* from sandbox to clear bwrap symlink overlay`
- `track(hook): gh artifact format skill + enforce body-file hook (issue/PR/comment discipline)`

## 2. Issue body (5 sections)

```markdown
## Context

What surfaced this issue? Which session / PR / fresh-clone smoke / external
report? Cite the upstream pain so future-you can judge whether the issue is
still load-bearing.

## Problem

The specific gap. Quote error messages. Cite file paths and line numbers.

## Proposal

What to do about it. Bullet list of concrete files to change / hooks to add /
scripts to wire up. Skip this section if the problem statement already implies
the fix.

## Acceptance criteria

What "done" looks like. Checklist of observable outcomes -- not "tests pass"
(that's table stakes), but "running X produces Y".

## Out of scope

What this issue intentionally does NOT cover. Prevents scope creep and gives
the reviewer permission to push back on extra work.
```

Small issues (one-line bug, trivial doc tweak) may collapse Proposal into Problem and drop Acceptance. **Context** and **Out of scope** stay -- they are the two sections that get retroactively wished-for most often.

## 3. Issue close comment (3 tiers)

Pick a tier based on the issue's history. The hook enforces two-step close (`gh issue comment N --body-file X && gh issue close N [--reason ...]`); the tier dictates how long X is.

### Decision record is mandatory (refs #196)

**The PR body is the canonical decision record.** A PR that closes an issue (`Closes`/`Fixes`/`Resolves #N` in its body) MUST contain a `## Resolution` or `## Decision` section stating what was decided and how it was resolved. `enforce_gh_body_file.sh` reads the `--body-file` content at `gh pr create` time and denies a closing PR that lacks the marker (Check A). It does not require a separate comment on the issue -- the merged PR's body is reachable from the issue via the "closed by PR #N" cross-reference.

**A manual close (no PR) must carry the record on the issue itself.** Because there is no PR body, `gh issue close N` is denied unless the issue already has a comment containing a `## Resolution` or `## Decision` heading (Check B; the hook queries `gh issue view N --json comments` and fails open if gh is unreachable). Consequence for the **Trivial** tier below: even a one-line close reason must now live in a `--body-file` whose first line is `## Resolution` (the inline single-line `--body` form cannot carry the heading). Keep it short, just structured:

```markdown
## Resolution

Repo description set via gh repo edit (no PR needed).
```

### Trivial

1-2 sentences. Since #196 the body must carry a `## Resolution` / `## Decision` heading (see above), so use a short `--body-file` rather than inline `--body`. Use when the issue closed without a PR or with one obvious commit.

Example: closing #45 (set repo description) with `--body "Repo description set via gh repo edit (no PR needed)"`.

### Standard

Multi-sentence body in `/tmp/issue-X-close.md`: result + reason + cross-ref to the landing PR / commit. Use when one PR closed the issue but the resolution needed explanation.

```
Closed by PR #82 (ci-wall-time-compare.sh). The original spec was for a
helper script; the implementation also added bats coverage and updated
TEST.md / CHANGELOG / CLAUDE.md tree to satisfy the "documented entry
point" rule from CLAUDE.md.
```

### Formal

Structured body with sub-sections. Use when the issue spawned >= 2 PRs, had cross-repo fanout, or the original acceptance criteria drifted during implementation and need explicit reconciliation.

```markdown
## Resolution

PR #81 (#77 sub-1) + PR #82 (#77 sub-2) + PR #83 (#77 sub-3) all merged.

## Acceptance check

| Original criterion | Status |
|---|---|
| stale `template/` ref detect | done (PR #81) |
| ci-wall-time-compare skill | done (PR #82) |
| `.claude/scripts/*` excludedCommands | done (PR #83) |

## Drift from spec

The hook (#77 sub-1) was scoped wider than the original "post-edit only"
proposal -- it also matches Dockerfile and Makefile under .base/, since
those are the other carriers of stale `template/` refs. No tests had to be
deleted; coverage is additive.
```

Both Standard and Formal close comments go through `/tmp/<name>.md` + `--body-file`.

## 4. Non-closing comments on issue / PR

Three categories. The hook applies the 80-char threshold uniformly, but the category drives whether you should even consider inline.

### Review-line (on a PR)

Tied to a specific `path:line`. Should be a few words plus the suggestion. Inline is fine when the comment is short:

```bash
gh pr review 9 --comment --body "nit: typo at line 42 (occured -> occurred)"
```

Long suggestions (multi-line diff blocks, multi-paragraph reasoning) go through `--body-file`.

### Status

"CI green, merging." "Blocked on dependabot rebase, will retry tonight." Almost always 1 line inline -- pure signal, no narrative.

```bash
gh pr comment 9 --body "CI green, merging via gh pr merge --auto."
```

### Decision

"Going with approach X because Y; alternatives Z were rejected for reason W."  Always goes to a file. These are the comments future-you wants to find via `gh pr view` six months later, and inline strings get lost in noise. Reuse the issue-body 5-section shape if the comment is long enough to warrant it (Context / Decision / Trade-offs / Out of scope).

```bash
gh pr comment 9 --body-file /tmp/decision-approach-A.md
```

## 5. Cross-ref keywords

GitHub recognises 5 keyword families plus regular text. Use them deliberately -- the auto-close ones are load-bearing.

| Keyword | Auto-close on merge? | When to use |
|---|---|---|
| `Closes #N` / `Fixes #N` / `Resolves #N` | Yes | Use in PR body when this PR fully resolves the issue. GitHub auto-closes #N on merge. |
| `refs #N` | No | Related but doesn't close. Use in commit message, PR body, or comment to thread context. Default for "this PR touches the same area as #N". |
| `supersedes #N` | No (manual close) | This PR / issue replaces #N. Reviewer should manually close #N once this lands. |
| `closes part of #N` | No (manual close) | Partial close. Use in sub-task PRs of a meta-issue. The meta-issue stays open until all parts are merged. |
| Bare `#N` (no keyword) | No | Just a hyperlink. Use sparingly -- prefer one of the keywords above so the relationship is explicit. |

Two notes on usage:

- `Closes #N` only auto-closes when the PR merges to the **default branch**. For PRs targeting a non-main branch, the issue stays open and you must close manually.
- Cross-repo refs work: `Closes ycpss91255-docker/base#282` from a `docker_harness` PR auto-closes the linked `base` issue when merged. Same keyword set.

## 6. Labels (issue create)

Every `gh issue create` must pass `--label <name>` (enforced by hook
rule 9). PRs are exempt -- they inherit labels from the issue they
close via `Closes #N`.

Map the title type prefix to a stock GitHub label:

| Title type | Label |
|---|---|
| `feat(*)` | `enhancement` |
| `refactor(*)` | `enhancement` |
| `chore(*)` | `enhancement` |
| `track(*)` | `enhancement` |
| `fix(*)` | `bug` |
| `docs(*)` | `documentation` |

Multiple labels are allowed and encouraged when applicable:
`--label "bug" --label "help wanted"`. Stock label inventory in every
org repo:

- `bug` / `enhancement` / `documentation` -- primary type axis (use one).
- `question` -- for issues that are really questions, not work items.
- `wontfix` / `invalid` / `duplicate` -- close-decision labels (apply
  on close, not on open).
- `good first issue` / `help wanted` -- visibility / recruitment.

The `base` repo additionally has `backlog` / `dependencies` /
`github_actions`. Those are not yet rolled out org-wide. Cross-repo
label inventory alignment is out of scope for #91 and tracked
separately.

Empty `--label ""` / `--label=` does not satisfy the rule. The hook is
lexical -- if the label name does not exist on the target repo, `gh`
itself errors out with a clear message; no API call from the hook.

## Quick reference

| Task | Inline OK? | Routing |
|---|---|---|
| Open an issue | n/a | `gh issue create --body-file /tmp/issue-X-open.md --label <name>` (Rules 1 + 9) |
| Open a PR | n/a | `gh pr create --body-file /tmp/pr-X-body.md` (Rule 4) |
| Edit a PR body | no | `gh pr edit N --body-file /tmp/pr-X-body.md` (Rule 6) |
| Trivial close | yes (<= 80) | `gh issue comment N --body "<short>"` then `gh issue close N --reason completed` |
| Standard / Formal close | no | `gh issue comment N --body-file /tmp/issue-X-close.md` then `gh issue close N --reason completed` |
| Status / review-line comment | yes (<= 80) | `gh pr comment N --body "<short>"` or `gh pr review N --comment --body "<short>"` |
| Long comment | no | `gh pr comment N --body-file /tmp/comment-X.md` |
| Reason-only close | n/a | `gh issue close N --reason "not planned"` (no `--comment`) |

If the body is >= 81 chars or has a newline, the hook denies the inline form and tells you to write a file. The threshold is intentionally low -- "short" should fit in a glance.

## Why hook + skill instead of slash commands

A skill teaches once and applies for the rest of the session. A per-artifact slash command (`/issue-open`, `/issue-close`, `/comment`) would force the agent to remember which command matches the current artifact type and to invoke each one explicitly; that's friction without payoff because the agent is already running `gh` commands. The hook fires automatically on every `gh` invocation; the skill is the doc that explains *why* the hook denies what it denies.

`/pr` keeps its current shape (slash command -- PR open is a multi-step workflow with branch, commit, push, auto-merge). Its body-shape section should refer to this skill rather than duplicating section names; that way the PR body shape stays in one place.
