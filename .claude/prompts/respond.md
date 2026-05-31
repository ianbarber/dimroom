# Stage: RESPOND TO REVIEW

You are addressing review feedback on a PR for **dimroom**. You will read every unresolved review comment, fix the code or push back, and re-submit the PR for review.

## Inputs

- `ISSUE_NUMBER`
- `PR_NUMBER`

## What to do

1. **Read context:**
   - `CLAUDE.md`
   - `gh pr view $PR_NUMBER --comments`
   - `gh api repos/{owner}/{repo}/pulls/$PR_NUMBER/comments` — line-level review comments (these are different from issue comments)
   - The PR diff: `gh pr diff $PR_NUMBER`
   - The original plan on the issue

2. **Set up.** `cd .worktrees/issue-${ISSUE_NUMBER}` (it should still exist from the implementer run). If it doesn't, recreate it from the PR branch:
   ```
   git worktree add .worktrees/issue-${ISSUE_NUMBER} <branch-name>
   ```
   **Then resume from the checkpoint** — see "Progress checkpoints & context handoff" below: run `bin/agent-checkpoint.sh phase .` and read its notes. A prior respond pass may have already fixed and replied to some comments before dying; the notes tell you which. Re-enumerate the comments anyway (step 3) and skip the ones already addressed (a pushed fix + a reply on the comment are idempotent observations). Once set up, checkpoint it: `bin/agent-checkpoint.sh write . comments-enumerated "starting respond pass" "$(git rev-parse HEAD)"`.

3. **Enumerate every unresolved review comment.** For each one, decide:

   - **Fix it:** make the change. Reply to the comment with `gh api` (create review comment reply) or as a top-level comment, citing the commit SHA. Be brief: "Fixed in abc1234 — extracted to helper."

   - **Push back:** reply explaining why you disagree, with specific reasoning. Don't be defensive; if the reviewer has a point you missed, just fix it. If you genuinely believe the reviewer is wrong, say so once, clearly, and let the human decide on the next pass.

   - **Defer:** if the comment asks for something outside the PR's scope, file a follow-up issue and reply with the issue link.

   You must address every comment one of these three ways. Silent ignores are not allowed.

4. **Re-run the verification ladder** for everything you touched:
   - `swift test` for affected packages
   - Snapshot tests
   - Harness flows (regenerate screenshots if any UI-affecting change happened)

   When the ladder is green, checkpoint it: `bin/agent-checkpoint.sh write . reverified "ladder green, ready to push" "$(git rev-parse HEAD)"`.

5. **Re-capture screenshots if UI changed.** Use `.claude/skills/capture-screenshots.md`. Replace the previous attachments by uploading new ones via `gh pr comment` and noting that they supersede the previous batch.

6. **Push.** New commits, not amended.
   ```
   git push
   ```
   Then checkpoint it: `bin/agent-checkpoint.sh write . fixes-pushed "fixes pushed, replies posted" "$(git rev-parse HEAD)"`.

7. **Set label back to `state:in-review`** (remove `state:changes-requested`).

8. **Stop.**

## Progress checkpoints & context handoff

A run can die mid-stage — a socket error, an API outage, or the per-session timeout (#374). This stage works in the persistent `.worktrees/issue-${ISSUE_NUMBER}` tree, so it checkpoints progress to `.agent-state.json` there to avoid re-doing fixes on retry.

- **The helper:** `bin/agent-checkpoint.sh write <dir> <phase> "<notes>" [sha]` writes the checkpoint atomically; `bin/agent-checkpoint.sh phase <dir>` prints just the recorded phase. Run them with `<dir>` = `.` from inside the worktree. The file is gitignored, so it never lands in the PR.
- **Milestones:** `comments-enumerated` → `reverified` → `fixes-pushed`. In the notes, record **which comments are already addressed** — that's the state git/GitHub can't show you at a glance, and it's what lets the next pass avoid re-fixing the same comment.
- **Resuming:** on a continuation, read the checkpoint, then re-enumerate the live review comments and skip the ones already fixed-and-replied.

**If you find you've used substantial context and still have a lot of comments to address, do NOT try to finish in one session.** Instead:

1. Write the current state: `bin/agent-checkpoint.sh write . <phase> "<comments addressed, comments remaining, any gotchas>" "$(git rev-parse HEAD)"`.
2. Commit and push what you have with a WIP message (`wip(area): partial review response — handoff, see .agent-state.json`).
3. **Leave the label at `state:changes-requested`** — do NOT set `state:in-review`. The next pass must be another responder run that re-enumerates the comments, not a review of half-addressed feedback.
4. Exit with a brief summary of which comments are done and which remain.

## Rules

- **Never amend or force-push.** The reviewer needs to see what you changed since their feedback. New commits, always.
- **Reply to every comment.** Even "fixed in <sha>" is enough. Silence is not.
- **Don't expand scope.** Address the feedback, nothing more. If you spot something else broken, file a separate issue.
- **If the feedback exposes a flaw in the original plan**, stop, comment on the issue describing the disconnect, set label to `state:blocked`, and let the human decide whether to re-plan.
- **Same hook/commit rules as IMPLEMENT.** No `--no-verify`, no force pushes, no merging.
