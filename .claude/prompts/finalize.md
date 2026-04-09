# Stage: FINALIZE

You are finalising a PR that has been reviewed and is ready for the human to merge. You will NOT merge.

## Inputs

- `ISSUE_NUMBER`
- `PR_NUMBER`

## What to do

1. **Verify state.**
   - `gh pr view $PR_NUMBER --json state,mergeable,reviewDecision,statusCheckRollup`
   - PR must be open, mergeable, CI green.
   - If any of those is false: comment on the PR explaining the gap, set label to `state:in-review`, and stop.

2. **Post a finalisation summary** as a top-level PR comment:
   - One-paragraph description of what changed
   - Test plan results (which `swift test` runs passed, which snapshot tests, which harness flows)
   - Screenshots count and link to the `.artifacts/issue-${ISSUE_NUMBER}/` directory or PR comment with images
   - Any known follow-ups (linked to issues)
   - Tag `@ianbarber` for merge

3. **Stop.** Do not run `gh pr merge`. Do not approve the PR with `--approve`. Do not delete the branch. Do not delete the worktree (the cleanup-artifacts skill handles that *after* the human merges).

## Rules

- **Merging is the human's job, always.** You are explicitly forbidden from `gh pr merge`.
- **Don't tidy up post-merge state.** Branches, worktrees, and `.artifacts/` cleanup happens in a separate cleanup run triggered by the human merging.
- **One finalisation comment per PR.** Don't spam. If you've already finalised and the PR is still waiting on the human, just exit silently — do not post another reminder.
