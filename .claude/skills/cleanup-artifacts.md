# Skill: cleanup-artifacts

Clean up branch-scoped artifacts after a PR is merged.

## When to use

- After the human merges a PR
- Triggered by `bin/agent-loop.sh --post-merge $PR_NUMBER` or by a workflow on `pull_request: closed` (merged)
- Never run on an open PR

## Inputs

- `PR_NUMBER`
- `ISSUE_NUMBER` (derive from `gh pr view $PR_NUMBER --json closingIssuesReferences`)
- `BRANCH` (derive from `gh pr view $PR_NUMBER --json headRefName`)

## Steps

### 1. Sanity-check the PR is actually merged

```bash
STATE=$(gh pr view "$PR_NUMBER" --json state,merged -q '"\(.state) \(.merged)"')
if [ "$STATE" != "MERGED true" ]; then
  echo "PR $PR_NUMBER is not merged ($STATE) — refusing to clean up"
  exit 1
fi
```

### 2. Remove the local worktree

```bash
WT=".worktrees/issue-${ISSUE_NUMBER}"
if [ -d "$WT" ]; then
  git worktree remove --force "$WT"
fi
```

### 3. Delete the local branch

```bash
git branch -D "$BRANCH" 2>/dev/null || true
```

### 4. Delete the screenshot artifacts

```bash
rm -rf ".artifacts/issue-${ISSUE_NUMBER}"
```

### 5. Delete the orphan artifacts branch (if it exists)

```bash
ARTIFACT_BRANCH="artifacts/$BRANCH"
if git ls-remote --exit-code origin "$ARTIFACT_BRANCH" >/dev/null 2>&1; then
  git push origin --delete "$ARTIFACT_BRANCH"
fi
```

### 6. Verify

```bash
git worktree list
git branch
ls .artifacts/ 2>/dev/null
```

None of these should still mention the cleaned-up issue or branch.

## Rules

- **Refuse to run on an unmerged PR.** Step 1 is non-negotiable.
- **Never delete `main` or `artifacts/main`.** If `BRANCH` is `main`, abort.
- **Never delete a branch with a different open PR.** Check before deleting.
- **PR comments and `user-attachments` images stay forever** — that's GitHub's call, not ours. We only clean up things we created in the repo.
