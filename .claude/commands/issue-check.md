Check open issues across `ycpss91255-docker` repos and surface what hasn't been handled.

Use this when you want a periodic sweep of unresolved issues — what's stale, what's blocked, what should be picked up next.

## Scope

Default: all repos under the `ycpss91255-docker` org.
If `$ARGUMENTS` names one or more repos (space-separated), scope to those only.

## Steps

### 1. Collect open issues

```bash
gh search issues "is:open org:ycpss91255-docker" \
  --json repository,number,title,author,labels,assignees,createdAt,updatedAt,url \
  --limit 200
```

If `$ARGUMENTS` is given, filter or use `gh issue list -R ycpss91255-docker/<repo>` per repo instead.

### 2. For each issue, gather context

- **Linked PRs**: `gh issue view <num> -R <repo> --json closedByPullRequestsReferences,timelineItems` — find PRs that reference / close this issue
- **Last activity**: latest of `updatedAt`, last comment, last linked-PR event
- **Recent comments** (if last activity > 7d ago): pull last 1-2 comments to understand current state

Skip issues that are clearly bot-driven noise (dependabot duplicates, etc.) unless `$ARGUMENTS` includes `--include-bots`.

### 3. Categorize

For each open issue, place it in exactly one bucket:

| Bucket | Criteria |
|--------|----------|
| **In progress** | Has open linked PR, or comment activity in last 7 days |
| **Ready to merge** | Has linked PR that's approved / passing CI but not merged |
| **Blocked** | Comment thread shows waiting on external decision / dep / discussion |
| **Stale** | No activity 30+ days, no linked PR, no recent comment |
| **Untriaged** | <14 days old, no label, no assignee — needs someone to look at it |
| **Orphaned** | Linked PR was closed without merge, or assignee left it >30d |

### 4. Output

**All output must be in Traditional Chinese** (keep issue titles in their original wording untranslated; write the suggested action / categorization / summary in Chinese).

Group by bucket (most-urgent first); within each bucket, group by repo. Per-issue format:

```
- <repo>#<num> <original title>  (建立 <age>，最後活動 <when>)
  → <one-sentence suggested action, in Chinese>
  <url>
```

Bucket titles are rendered in Chinese:
- 進行中（In progress）
- 可 merge（Ready to merge）
- 卡住（Blocked）
- 停滯（Stale）
- 待分類（Untriaged）
- 孤兒（Orphaned）

End with a one-line summary in Chinese:
```
共 N 個 open · X 進行中 · Y 可 merge · Z 停滯 · ...
```

Report only; do not take any automatic action (add label / close issue / comment). The user decides what to act on.

## Notes

- Use `gh` (not raw API) for everything — auth is already configured
- Don't fetch full comment history for every issue (rate limits); only when last-activity heuristic flags it as worth looking deeper
- If no open issues exist in scope, just say so — don't pad the report

Context from user: $ARGUMENTS
