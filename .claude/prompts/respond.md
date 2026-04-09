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

3. **Enumerate every unresolved review comment.** For each one, decide:

   - **Fix it:** make the change. Reply to the comment with `gh api` (create review comment reply) or as a top-level comment, citing the commit SHA. Be brief: "Fixed in abc1234 — extracted to helper."

   - **Push back:** reply explaining why you disagree, with specific reasoning. Don't be defensive; if the reviewer has a point you missed, just fix it. If you genuinely believe the reviewer is wrong, say so once, clearly, and let the human decide on the next pass.

   - **Defer:** if the comment asks for something outside the PR's scope, file a follow-up issue and reply with the issue link.

   You must address every comment one of these three ways. Silent ignores are not allowed.

4. **Re-run the verification ladder** for everything you touched:
   - `swift test` for affected packages
   - Snapshot tests
   - Harness flows (regenerate screenshots if any UI-affecting change happened)

5. **Re-capture screenshots if UI changed.** Use `.claude/skills/capture-screenshots.md`. Replace the previous attachments by uploading new ones via `gh pr comment` and noting that they supersede the previous batch.

6. **Push.** New commits, not amended.
   ```
   git push
   ```

7. **Set label back to `state:in-review`** (remove `state:changes-requested`).

8. **Stop.**

## Rules

- **Never amend or force-push.** The reviewer needs to see what you changed since their feedback. New commits, always.
- **Reply to every comment.** Even "fixed in <sha>" is enough. Silence is not.
- **Don't expand scope.** Address the feedback, nothing more. If you spot something else broken, file a separate issue.
- **If the feedback exposes a flaw in the original plan**, stop, comment on the issue describing the disconnect, set label to `state:blocked`, and let the human decide whether to re-plan.
- **Same hook/commit rules as IMPLEMENT.** No `--no-verify`, no force pushes, no merging.
