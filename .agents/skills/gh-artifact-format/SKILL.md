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

**Five managed labels, on two orthogonal axes. Nothing else is
managed.** ADR-00000015 carries the reasoning and the measurements
behind the set; this section is the operating instruction.

Every `gh issue create` must pass `--label <name>` (hook rule 9). The
hook check is lexical -- it requires a non-empty `--label`; picking the
right one is on you. PRs are exempt: they inherit labels from the issue
they close via `Closes #N`.

### Axis 1 -- kind (exactly one, required at create)

Derive it mechanically from the title type prefix (section 1):

| Title type | Label |
|---|---|
| `feat(*)` | `enhancement` |
| `refactor(*)` | `enhancement` |
| `chore(*)` | `enhancement` |
| `track(*)` | `enhancement` |
| `fix(*)` | `bug` |
| `docs(*)` | `documentation` |

Four of the six prefixes land on `enhancement`. That is why
ADR-00000015 defines the label **by exclusion** -- "work that is
neither a defect fix nor documentation" -- instead of as GitHub's "new
feature requests": most of what carries it is refactors, chores and
tracking issues, not features. The finer distinction is already in the
title prefix, so splitting the label would buy nothing.

| Label | Description (canonical, from `labels.yaml`) |
|---|---|
| `bug` | A defect in shipped behaviour |
| `documentation` | Documentation only, no behaviour change |
| `enhancement` | Work that is neither a defect fix nor documentation |

### Axis 2 -- state (at most one, optional)

| Label | Description (canonical, from `labels.yaml`) |
|---|---|
| `backlog` | Deliberately not scheduled |
| `ready-for-agent` | Spec is complete: seams, first slice, gate, bound |

The axes are independent: a `bug` may be `ready-for-agent`, an
`enhancement` may be `backlog`. Carrying **neither** state label means
the scheduling question has not been answered yet -- which is why
`triage` is not in the set: it said the same thing a second time.

`backlog` is fine at create time
(`--label enhancement --label backlog`). `ready-for-agent` normally
arrives later, via `gh issue edit N --add-label ready-for-agent` -- and
that is precisely the command section 7's gate reads, denying it until
the four headings are present. Section 6 says which labels exist;
section 7 says what the one label with a precondition costs.

### Where the five come from

`ycpss91255-docker/.github` holds `labels.yaml` as the org source of
truth, plus `script/sync-labels.sh` (`--apply` backfills a repo,
`--dry-run` reports drift) and a weekly drift cron
(ycpss91255-docker/.github#25). The same five strings are also the
org-level default labels, so a repo created now starts with them and
nothing else (ycpss91255-docker/.github#26). Never edit a managed label
in the GitHub UI -- the next sync reverts it; edit `labels.yaml`, get
review, then sync.

Backfill of the existing repos is still in flight, so a repo may not
carry `backlog` / `ready-for-agent` yet. If the name does not exist on
the target repo, `gh` itself errors out with a clear message (the hook
makes no API call); run `script/sync-labels.sh --apply --repo <name>`
from a `.github` checkout rather than inventing a substitute.

Anything else on a repo is unmanaged and not part of the vocabulary:
GitHub's six never-used defaults (`duplicate`, `good first issue`,
`help wanted`, `invalid`, `question`, `wontfix`) are left wherever they
already exist, and `dependencies` / `github_actions` belong to
Dependabot. Do not reach for them -- close decisions are carried by
GitHub's own close reasons (`gh issue close --reason "not planned"`),
not by a label.

Empty `--label ""` / `--label=` does not satisfy rule 9.

## 7. `ready-for-agent` -- the four headings

Of the five managed labels in section 6, `ready-for-agent` is the only
one that costs something to apply -- it is not a feeling. Per
ADR-00000015 it asserts that four things are present in the issue, and
`enforce_ready_for_agent.sh` BLOCKS
`gh issue edit N --add-label ready-for-agent` until they are.

Write them under these headings, exactly:

```markdown
## Seams
## First slice
## Gate
## Bound
```

- **Seams** -- which files change, what the interface is.
- **First slice** -- the first failing test to write.
- **Gate** -- the command that decides done.
- **Bound** -- how many red-green cycles before stopping.

**Headings fixed, prose free.** The implementer is an LLM and reads
prose fine; the headings exist only so "are all four present" is
machine-answerable. Any heading level from `##` down counts, and
trailing prose on the heading line is fine (`## Bound -- 10 cycles`).

**Put them in a COMMENT, not the body.** The body stays the original
spec (the issue-scope-change-in-comments rule), so a grill writes its
conclusions back as a comment. Both gates read the body and the
comments together, so parts may be split across them.

`.claude/scripts/check-ready-for-agent.sh <issue>` answers the same
question outside the hook -- exit 0 ready, 1 with the missing parts on
stdout, 2 when gh cannot be asked.

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
