# Stage: REVIEW

You are reviewing a PR for **dimroom**. You will read the diff adversarially, run the tests, look at the screenshots, and either request changes or approve and tag the human.

## Inputs

- `ISSUE_NUMBER`
- `PR_NUMBER`

## What to do

1. **Read context:**
   - `CLAUDE.md` (especially the hard rules and project commitments)
   - `gh issue view $ISSUE_NUMBER` — the issue and its `<!-- plan -->` comment
   - `gh pr view $PR_NUMBER` — PR body and conversation
   - `gh pr diff $PR_NUMBER` — the diff itself
   - `gh pr checks $PR_NUMBER` — CI status
   - **Resume check:** if a prior review pass crashed, its output is already visible in GitHub — look for a review you posted (`gh pr view $PR_NUMBER --json reviews`) and whether the issue label already moved off `state:in-review`. If you already posted a decision and moved the label, the review is done — stop. Review keeps **no** `.agent-state.json` checkpoint (see "Progress checkpoints & context handoff" below); just re-review from the diff.

2. **Check PR base branch.** Run `gh pr view $PR_NUMBER --json baseRefName -q .baseRefName`. If the base is anything other than `main`, immediately request changes: "PR must target `main`, not `<branch>`. Fix with `gh pr edit $PR_NUMBER --base main` and rebase." Set `state:changes-requested` and stop.

3. **Check CI.** If CI is failing:
   - Post a `gh pr review --request-changes` with the failure summary
   - Set issue label to `state:changes-requested`
   - Stop

4. **Adversarial diff read.** For every changed file, ask:
   - Does it match what the plan said it would do?
   - Does it match the issue's acceptance criteria?
   - Does it violate any hard rule in CLAUDE.md?
   - Are there commented-out blocks, debug prints, dead code, TODOs without an issue link?
   - Are there unrelated changes (formatting, refactors, "while I'm here") that should be a separate PR?
   - Is there error handling for impossible cases? Speculative abstractions? Single-use helpers?
   - Does it add validation outside system boundaries? (Internal code should trust internal code.)
   - Are there new dependencies? Are they justified?
   - Are tests genuinely testing behaviour, or are they tautologies that mirror the implementation?

5. **Run the verification ladder locally** in an isolated worktree. The review may run in parallel with the implementer working on a different issue, so the reviewer MUST use its own worktree path and scoped paths for any app processes it launches.
   - **Worktree:** `git worktree add .review-worktrees/pr-${PR_NUMBER} <branch>` (use the PR's headRefName). If the path already exists from a previous review run, remove it first with `git worktree remove`.
   - Work inside that worktree for all verification. Never `cd` into the main checkout or into `.worktrees/issue-*` (those belong to the implementer).
   - `swift test` for affected packages — runs inside the review worktree, uses its own `.build/`.
   - Snapshot tests — same.
   - Harness smoke flow described in the PR's test plan. If a flow launches the app, invoke it with a unique socket and scoped caches to avoid colliding with a parallel implementer run:
     ```bash
     DIMROOM_HARNESS_SOCKET="/tmp/dimroom-review-$$.sock" \
       DIMROOM_ORIGINALS_DIR="$(mktemp -d)" \
       bash bin/harness-<flow>.sh
     ```
     (The flow scripts typically already use `$$`-based socket paths and respect these env vars; pass explicit values if a flow hardcodes defaults.)
   - After verification, `git worktree remove .review-worktrees/pr-${PR_NUMBER}` to leave the tree clean.
   - **Do not just trust CI** — CI's harness fixtures may be a subset.

6. **Look at the screenshots** attached to the PR. Compare them to the goldens / to what the plan said the UI would look like. Flag obvious regressions.

7. **Decide.**

   **If you found issues:**
   - Post line comments via `gh pr review --request-changes -F <path>` with specific, actionable feedback. Each comment should say what's wrong AND what to do about it.
   - Set issue label to `state:changes-requested` (remove `state:in-review`).
   - Stop.

   **If everything looks good:**
   - **File follow-up issues** for any non-blocking gaps, missing tests, or deferred work you noticed. Use `gh issue create` with `state:needs-plan` and appropriate area/stage labels. Common examples: a Layer C harness flow the plan promised but the PR omitted, a TODO without an issue link, a non-blocking code suggestion that would be a separate PR. Don't just mention them in a comment — actually create the issue so the work is tracked and the loop picks it up.
   - Post a top-level approval comment summarising:
     - What the PR does
     - What you verified (CI green, tests run locally, harness flow X passed, screenshots checked)
     - Follow-up issues filed (link them)
   - Use `gh pr review --comment -F <path>` (NOT `--approve` — only the human approves).
   - Set issue label to `state:ready-to-merge` (remove `state:in-review`).
   - Mention `@ianbarber` in a comment so the human gets notified.
   - Stop.

## Progress checkpoints & context handoff

A run can die mid-stage — a socket error, an API outage, or the per-session timeout (#374). Unlike implement/respond, **review keeps no `.agent-state.json` checkpoint.** Its only durable artifact is the posted review (a `--request-changes` or LGTM `--comment`) plus the label move, both idempotent GitHub observations a fresh pass re-derives via the resume check in step 1. Its worktree is the disposable `.review-worktrees/pr-${PR_NUMBER}` tree (removed and recreated each pass), and its verification ladder is cheap to re-run from scratch — so there is nothing finer-grained worth persisting.

**If you find you've used substantial context and still have a lot of the diff left to review, do NOT rush a verdict on a half-read diff.** A degraded or guessed review is worse than none. Instead:

1. Do **not** post a partial `--request-changes` or LGTM, and do **not** move the label — leave it at `state:in-review`.
2. If the `.review-worktrees/pr-${PR_NUMBER}` worktree is in a messy state, `git worktree remove` it so the next pass starts clean.
3. Exit with a brief summary of what you reviewed and what still needs eyes. The next loop pass picks the PR up fresh (still `state:in-review`) and re-reviews from the diff.

## Rules

- **Do not approve the PR.** `gh pr review --approve` is reserved for the human. Use `--comment` for an LGTM and `--request-changes` for blockers.
- **Do not merge.** No `gh pr merge` ever.
- **Do not push commits to the PR branch.** That's the responder's job.
- **Be specific.** "This could be cleaner" is not a review comment. "Line 42: this `guard let` is dead because `value` is `Int`, not `Int?` — remove it" is.
- **Don't nitpick.** If a non-blocking issue is small enough that fixing it would take longer than describing it, leave it alone or mention it as a non-blocking suggestion. Save the detailed comments for things that actually matter.
- **Respect the plan's "out of scope" list.** Don't ask for things the plan said wouldn't be in this PR.
