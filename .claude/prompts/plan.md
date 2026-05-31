# Stage: PLAN

You are planning a GitHub issue for **dimroom**. You will not write any code in this run. You will read the issue, read the code, and post a single plan comment.

## Inputs (provided as env vars by the loop)

- `ISSUE_NUMBER` — the issue number to plan
- `ISSUE_TITLE`
- `ISSUE_BODY`

## What to do

1. **Read context, in this order, before planning anything:**
   - `CLAUDE.md` (project rules — non-negotiable)
   - The full issue body via `gh issue view $ISSUE_NUMBER`
   - The README's delivery stages section (to understand which stage this issue belongs to)
   - Any package READMEs under `Packages/*/README.md` that the issue touches
   - Any prior `<!-- plan -->` comment on the issue. **This is also the resume signal:** if a `<!-- plan -->` comment already exists and the label is already `state:planned`, a prior pass finished — there is nothing to do, so stop. If the comment exists but the label hasn't moved, just re-post/finish the plan and move the label. Planning keeps **no** `.agent-state.json` checkpoint (see "Progress checkpoints & context handoff" below).

2. **Validate the issue is plannable.** If any of these are true, do NOT plan — instead post a clarifying comment, set the label to `state:blocked`, and stop:
   - Goal is unclear or missing
   - Acceptance criteria are missing
   - The issue spans multiple stages and should be split
   - Required decisions are unresolved (read the comments)

3. **Produce a plan** as a single GitHub comment with this exact structure. Wrap it in an HTML marker so the implementer can find it:

   ```markdown
   <!-- plan -->
   ## Plan for #ISSUE_NUMBER

   ### Approach
   <2–4 sentences. The shape of the solution. Not the code.>

   ### Files to touch
   - `path/to/file.swift` — what changes
   - …

   ### New files to create
   - `path/to/new.swift` — purpose
   - …

   ### Tests to add
   - **Layer A:** package tests for X covering Y, Z
   - **Layer B:** snapshot test for view N (if applicable)
   - **Layer C:** harness flow `flow-name.json` driving these commands: …

   ### Risks / open questions
   - …

   ### Out of scope (do not do in this PR)
   - …

   ### Estimated size
   <xs / s / m / l>
   ```

4. **Post the plan** with `gh issue comment $ISSUE_NUMBER --body-file <path>`.

5. **Move the label**: remove `state:needs-plan`, add `state:planned`.
   ```
   gh issue edit $ISSUE_NUMBER --remove-label state:needs-plan --add-label state:planned
   ```

6. **Stop.** Do not create a branch. Do not write code. Do not start implementing.

## Progress checkpoints & context handoff

A run can die mid-stage — a socket error, an API outage, or the per-session timeout (#374). **Planning keeps no `.agent-state.json` checkpoint.** It runs in the main checkout with no worktree, and its sole artifact is the idempotent `<!-- plan -->` issue comment; a fresh pass re-derives where it stands from whether that comment exists and whether the label has moved (the resume signal in step 1). The compute to re-plan from scratch is cheap.

**If you find you've used substantial context and the plan still isn't ready, do NOT post a half-formed plan.** A vague plan misleads the implementer. Instead: post nothing (or, if you've already drafted partial notes worth keeping, post them clearly marked as a draft), leave the label at `state:needs-plan`, and exit with a one-line note on what's still undecided. The next loop pass plans the issue fresh.

## Rules

- **Do not modify any tracked files.** No git operations except `gh issue comment` and `gh issue edit`.
- **Do not invent acceptance criteria.** If the issue doesn't have them, the issue is blocked.
- **Be specific.** A plan that says "add a service for X" without naming the file is not a plan.
- **Respect project commitments.** If the most natural plan would violate a hard rule in CLAUDE.md, surface the conflict in "Risks / open questions" and set `state:blocked` instead.
- **One plan per run.** If `ISSUE_NUMBER` is missing or empty, exit immediately.
