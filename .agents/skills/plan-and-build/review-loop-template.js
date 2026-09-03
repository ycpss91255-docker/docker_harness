// plan-and-build — review-loop template.
//
// The sibling of workflow-template.js. That one drives a single implementer
// to green. This one drives fix -> review -> fix over an existing branch and
// decides whether the branch may be published.
//
// It exists because the obvious loop does not terminate. A gate written as
// "land only when the review closed" has one direction: it can refuse. It
// cannot decide that a round's findings are not about the branch under
// review. Reviewers open new findings faster than they close the round's own,
// the round budget runs out, and the script exits with the branch complete,
// committed and unpublished — which looks exactly like a script that had
// nothing to do.
//
// Three things fix that, and all three are structural, not prose:
//   1. Every finding is classified in-scope / out-of-scope BEFORE it can gate.
//   2. Out-of-scope findings leave as follow-up issues, so deferring one
//      loses nothing and the loop is allowed to converge.
//   3. The accounting phase is OUTSIDE the loop and unconditional, so a run
//      that stops holding unpushed commits says so.

export const meta = {
  name: 'review-loop-run',
  description: 'Fix, review and account for one branch, with scope-classified findings',
  phases: [
    { title: 'Fix', detail: 'close the in-scope findings' },
    { title: 'Review', detail: 'find, and classify each finding by scope' },
    { title: 'Account', detail: 'report what is on disk, landed or not' },
  ],
}

// ---- CONFIG -----------------------------------------------------------
const WORKTREE = '<absolute path to the worktree>'
const REPO = '<owner/repo that worktree belongs to>'
const ISSUE = '<issue number this implements>'
const BRANCH = '<branch name in that worktree>'
const GATE = 'just test'

// The change under review, in one paragraph. The reviewer needs this to
// classify scope; without it every defect in the file reads as in-scope.
const INTENT = `
<what this branch set out to change, and what it deliberately did not>
`

// Hard bound. Not a target — a bound. See "Why the budget is a failure",
// below.
const MAX_ROUNDS = 3
// -----------------------------------------------------------------------

// The classification rule, stated once and quoted into both agents so they
// cannot drift apart.
const SCOPE_RULE = `
SCOPE — every finding is in-scope or out-of-scope for THIS branch. Decide it
with two questions, in order, and stop at the first yes:

  Q1. Did this branch introduce it?
      A functional defect in a line this branch wrote or changed, or a claim
      this branch's commit message / PR body makes that is false.
      -> IN SCOPE. Never deferrable, whatever the severity.

  Q2. Is it the unfixed sibling of a shape this branch DID change?
      The mirrored scaffold, the commented copy, the other physical line of
      the same statement, the other spelling of the same shape. Half a shape
      fixed is a defect this branch introduced.
      -> IN SCOPE.

  Otherwise -> OUT OF SCOPE. This is the default, and it is where an
  uncertain call goes.

Out of scope covers, explicitly: a pre-existing defect you noticed while
reading; the same class of defect at a site this branch did not touch; a
follow-up this change makes visible without introducing; a design you would
have done differently; anything about a neighbouring module.

WHY THE DEFAULT IS "OUT". Nothing is lost by it. An out-of-scope finding is
filed as an issue before the branch is published, so the deferral is recorded
and recoverable. The opposite default loses the branch: it holds finished work
behind a bar that the next round's new findings raise again, forever. Losing a
finding is the failure mode a follow-up issue prevents; never landing is the
failure mode nothing prevents.

Q1 is the guard against abusing that default. A regression this branch
introduced is in scope no matter how it is phrased.
`

const FINDING = {
  type: 'object',
  additionalProperties: false,
  required: ['scope', 'severity', 'file', 'line', 'claim', 'evidence', 'whichQuestion'],
  properties: {
    scope: { type: 'string', enum: ['in', 'out'] },
    severity: { type: 'string', enum: ['major', 'minor'] },
    file: { type: 'string' },
    line: { type: 'string' },
    claim: { type: 'string', description: 'one sentence: what is wrong' },
    evidence: { type: 'string', description: 'the input and the observed wrong output, run not reasoned' },
    whichQuestion: {
      type: 'string',
      enum: ['Q1', 'Q2', 'default'],
      description: 'which of the two scope questions decided this, or the default',
    },
  },
}

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['findings', 'gateOutcome'],
  properties: {
    findings: { type: 'array', items: FINDING },
    gateOutcome: { type: 'string', description: 'the TAP plan line and any not ok, verbatim' },
  },
}

const FIX_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['closed', 'stillOpen', 'commits', 'gateOutcome'],
  properties: {
    closed: { type: 'string', description: 'one line per finding closed, with the commit that closed it' },
    stillOpen: { type: 'string', description: 'findings not closed and exactly why; empty if none' },
    commits: { type: 'string', description: 'commit subjects created this round, in order' },
    gateOutcome: { type: 'string', description: 'the TAP plan line and any not ok, verbatim' },
  },
}

// The accounting schema asks for what is ON DISK. A workflow script has no
// filesystem access, so "did this run leave work behind" cannot be inferred
// from control flow — it has to be read off the worktree by an agent, and
// that read has to happen on every path out of the script.
const ACCOUNT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['headSha', 'unpushedCommits', 'workingTreeDirty', 'gateOutcome'],
  properties: {
    headSha: { type: 'string' },
    unpushedCommits: {
      type: 'string',
      description: 'subjects of commits on the branch that are not on origin, one per line; "none" if the branch is published',
    },
    workingTreeDirty: { type: 'string', description: 'git status --porcelain output, or "clean"' },
    gateOutcome: { type: 'string', description: 'the TAP plan line and any not ok, verbatim' },
  },
}

const CONTEXT = `
WORKTREE: ${WORKTREE}   (a checkout of ${REPO}; sibling repos are NOT present)
BRANCH:   ${BRANCH}
ISSUE:    #${ISSUE}

WHAT THIS BRANCH IS FOR:
${INTENT}

GATE: run \`${GATE}\` from the worktree. Tail or grep its output rather than
reading it whole. Look for the TAP plan line and any \`not ok\`. Interact with
docker only through \`just\` recipes — never raw \`docker\`.

Git artifacts are plain English; a hook blocks CJK. No AI attribution lines.
`

const followUps = []
let round = 0
let openInScope = []

while (round < MAX_ROUNDS) {
  round += 1

  const review = await agent(
    `${CONTEXT}

Review this branch against origin/main. Read the diff, then verify by RUNNING,
not by reasoning: an evidence field that describes what the code would do is
not evidence.

${SCOPE_RULE}

Report every finding you are confident in, each with its scope and which
question decided it. Report the gate outcome whether or not you found
anything.`,
    { label: `review:r${round}`, phase: 'Review', schema: REVIEW_SCHEMA },
  )

  const found = review?.findings ?? []
  followUps.push(...found.filter((f) => f.scope === 'out'))
  openInScope = found.filter((f) => f.scope === 'in')

  log(`round ${round}: ${openInScope.length} in-scope, ${found.length - openInScope.length} deferred`)
  if (!openInScope.length) break

  const brief = openInScope
    .map((f, i) => `FINDING ${i + 1} (${f.severity}) — ${f.file}:${f.line}\n${f.claim}\n\nEvidence: ${f.evidence}`)
    .join('\n\n')

  const fix = await agent(
    `${CONTEXT}

Close exactly the findings below. Nothing else.

When you close one, close its SIBLING in the same commit — the mirrored
scaffold, the commented copy, the other physical line of the same statement.
That is the one form of extra work required, and it is required because half a
shape fixed is a new defect.

Anything ELSE you notice: do NOT fix it. Name it in stillOpen and move on.
${SCOPE_RULE}

Split commits red -> green: the failing test is its own commit, the
implementation that makes it pass is the next. Run the gate after every green.

${brief}`,
    { label: `fix:r${round}`, phase: 'Fix', schema: FIX_SCHEMA },
  )

  log(`round ${round}: ${fix?.gateOutcome ?? 'gate not reported'}`)
}

// UNCONDITIONAL. Not inside the loop, not behind an `if`. Every path out of
// this script passes through here, including budget exhaustion — which is the
// path that used to exit silently.
phase('Account')

const account = await agent(
  `${CONTEXT}

Report the state of this worktree. Do not fix anything, do not commit, do not
push. Run and report verbatim:

  git -C ${WORKTREE} rev-parse HEAD
  git -C ${WORKTREE} log --oneline origin/${BRANCH}..HEAD   (if the remote branch exists)
  git -C ${WORKTREE} log --oneline origin/main..HEAD        (if it does not)
  git -C ${WORKTREE} status --porcelain
  ${GATE}`,
  { label: 'account', phase: 'Account', schema: ACCOUNT_SCHEMA },
)

const exhausted = openInScope.length > 0

if (exhausted) {
  log(`BUDGET EXHAUSTED after ${MAX_ROUNDS} rounds — ${openInScope.length} in-scope finding(s) still open on ${BRANCH} at ${account?.headSha}`)
}
if (account?.unpushedCommits && account.unpushedCommits !== 'none') {
  log(`UNPUBLISHED WORK on ${BRANCH}: ${account.unpushedCommits}`)
}

return {
  // The planner reads landable FIRST. False is a reported failure, not a
  // quiet one: openInScope names what is still wrong, and unpushed names
  // what is sitting on disk because of it.
  landable: !exhausted,
  branch: BRANCH,
  headSha: account?.headSha,
  roundsUsed: round,
  openInScope,
  // File these as issues and cross-reference them from the PR body BEFORE
  // opening the PR. That obligation is what makes the "out" default safe.
  followUps,
  unpushed: account?.unpushedCommits,
  dirty: account?.workingTreeDirty,
  gateOutcome: account?.gateOutcome,
}
