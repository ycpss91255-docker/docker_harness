Run the project's "變更完成 checklist" (change-completion checklist) doc-alignment checks against the current working tree, before commit. Report what's missing — don't auto-fix unless asked.

Usage: `/doc-sync` (no args), or `/doc-sync <repo-path>` to scope to a single repo subtree.

For the path: $ARGUMENTS — if empty, default to `${CLAUDE_PROJECT_DIR}` (session cwd) and run the checks against every repo under it that has a `doc/test/TEST.md` (skip directories without that marker). When invoked from a per-repo session, this naturally scopes to that single repo; from workspace cwd it covers all sub-repos.

For each in-scope repo, run these checks and collect findings:

**1. TEST.md per-section count drift**
For every `### test/<rel>.bats (N)` heading across the `doc/test/*.md` catalogs (post-#695 split: `unit.md` / `integration.md` / `behavioural.md` / `smoke.md`; the glob still covers a single unsplit `TEST.md`), count `^@test` in the corresponding `test/<rel>.bats` file. Report any mismatch with both numbers (catalog says X, actual Y). Also flag headings whose path doesn't exist on disk, and `.bats` files not listed in any catalog at all.

**2. TEST.md total**
The `doc/test/TEST.md` index header line `**N tests** total (X unit + Y integration)` — verify N matches the sum of per-section counts across the catalogs AND the actual @test totals. If unit/integration split is given, verify those subtotals too.

**3. CHANGELOG `[Unreleased]` freshness**
If the working tree (or staged area, when in a git repo) has any modifications under the repo, check that the **live changelog**'s `[Unreleased]` section has at least one bullet that wasn't there at HEAD. The live changelog is the file under `doc/changelog/` carrying `## [Unreleased]` — on a pre-split repo that is `CHANGELOG.md`, and on a repo that has split its changelog per series (`ycpss91255-docker/base`#926) it is the series file, while `CHANGELOG.md` is a generated index no commit may hand-edit. Ask for it rather than assuming: `.claude/scripts/lib/changelog-path.sh` exposes `changelog_live_rel <repo-root>`. Then `git diff HEAD -- <that path>` — if no change touches `[Unreleased]`, warn (it might still be correct for pure refactors; flag, don't fail).

**4. 4-language README structural alignment**
Compare `README.md` (root) against `doc/readme/README.zh-TW.md`, `README.zh-CN.md`, `README.ja.md`. Specifically: count `^## ` and `^### ` headings in each — they should match. If counts diverge, list which language is missing/extra which heading. Tree-of-contents-only check; do NOT compare body content.

**5. Emoji scan**
Run `.claude/hooks/check_no_emoji.sh` against every file changed since HEAD (use `git status --porcelain` if git repo, else `find -newer` against a 24h window as fallback). Report any hits — those violate the project rule "不使用 emoji" (no emoji).

**6. AI attribution scan**
Grep changed files for these forbidden patterns (CLAUDE.md rule "不加 AI 歸屬標記", no AI-attribution markers):
- `Generated with .*Claude Code`
- `Co-Authored-By: Claude`
- `🤖 Generated`

Report hits with file:line.

## Output format

Group findings by repo. For each repo with findings, print a compact bulleted list. End with a clear summary line: `doc-sync: PASS` (no findings) or `doc-sync: <N> issue(s) — see above` (with findings). Do not auto-fix; the user decides whether to fix and re-run, or commit anyway.

If everything is clean, just print `doc-sync: PASS` and stop — don't pad with check-by-check confirmations.
