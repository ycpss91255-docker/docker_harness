// plan-and-build — Workflow script template.
//
// Copy this into a Workflow({script: ...}) call and fill the CONFIG block.
// The planner has already created WORKTREE and filed ISSUE; this script only
// drives the implementation half.
//
// The prompt below deliberately restates repo conventions. They do NOT travel
// with a subagent: an implementer that is not told to use `just` will reach
// for raw docker, and one that is not told the tdd skill lives at the
// workspace path will look for it in the worktree, where it does not exist.

export const meta = {
  name: 'plan-and-build-run',
  description: 'Implement one planned slice-chain in a worktree under TDD',
  phases: [{ title: 'Implement', detail: 'red -> green -> refactor against the gate' }],
}

// ---- CONFIG -----------------------------------------------------------
const WORKTREE = '<absolute path to the worktree the planner created>'
const REPO = '<which repo that worktree belongs to>'
const ISSUE = '<issue number this implements>'
const GATE = `just -f ${WORKTREE}/.claude/test/justfile check`
const TDD_SKILL = '/home/yunchien/workspace/docker/.claude/skills/tdd/SKILL.md'

const SEAMS = `
<the interface / seams the planner fixed>
`
const FIRST_SLICE = `
<the FIRST behaviour to test, and nothing beyond it>
`

// Hard bound. A gate proves the tests pass; it cannot prove the code is
// right, so an unbounded loop converges on plausible green, not on correct.
const MAX_CYCLES = 6
// -----------------------------------------------------------------------

const SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['reachedGreen', 'cyclesUsed', 'slices', 'commits', 'blockedOn', 'notes'],
  properties: {
    reachedGreen: { type: 'string', description: 'yes / no' },
    cyclesUsed: { type: 'string', description: 'how many red-green cycles were spent' },
    slices: { type: 'string', description: 'one line per slice: the behaviour, and whether it went green' },
    commits: { type: 'string', description: 'the commit subjects created, in order' },
    blockedOn: { type: 'string', description: 'if it stopped short, exactly what blocked it; empty otherwise' },
    notes: { type: 'string', description: 'anything the planner must know before opening the PR' },
  },
}

phase('Implement')

const result = await agent(
  `Implement one planned change, test-first, inside an existing git worktree.

WORKTREE: ${WORKTREE}   (this is a checkout of ${REPO} — do not assume sibling
repos are present; agent/*, app/*, env/* are separate repos and their files
are NOT in this worktree)

ISSUE: #${ISSUE}

METHOD: follow the TDD skill at ${TDD_SKILL}. Read it before starting. Do not
look for it under the worktree — it is a machine-local install and is not
reproduced inside worktrees.

SEAMS (fixed by the planner, do not redesign):
${SEAMS}

FIRST SLICE — implement exactly this first, and nothing beyond it:
${FIRST_SLICE}

Then derive each subsequent slice from what the previous cycle taught you. Do
NOT write the full test list up front: that is the horizontal-slicing
anti-pattern the TDD skill rejects. One test -> one implementation -> repeat.

GATE (run it after every green; it is the definition of done):
    ${GATE}
Tail or grep its output rather than reading it whole — a full run prints tens
of kilobytes. Look for the TAP plan line and any \`not ok\`.

REPO CONVENTIONS (these do not travel with you — follow them explicitly):
- Interact with docker through \`just\` recipes, never raw \`docker\` commands.
- Git artifacts (commit messages) are plain English. No CJK. A hook blocks it.
- No AI attribution lines in commits or code comments.
- Split commits red -> green: the failing test is its own commit, the
  implementation that makes it pass is the next.

SCOPE — stay inside these lines. Everything else is the planner's job:
- DO: edit files in the worktree, run the gate, commit in the worktree.
- DO NOT: create branches or worktrees, run batch scripts, upgrade .base,
  push, open or merge PRs, or write any checkpoint .ack file. If you find you
  need one of those, that is a planning gap — stop and report it in blockedOn
  rather than working around it.

STOPPING CONDITION — hard bound of ${MAX_CYCLES} red-green cycles. If the gate
is still not green when you reach it, STOP. Report what is failing in
blockedOn. Do not keep going: grinding a test until it passes produces green
that means nothing.

Report via the structured schema.`,
  { label: `implement-${ISSUE}`, phase: 'Implement', schema: SCHEMA },
)

return result
