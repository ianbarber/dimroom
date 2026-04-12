# Stage: IMPLEMENT

You are implementing a planned issue for **dimroom**. You will write code, run tests, capture screenshots, push a branch, and open (or update) a PR. You will NOT merge.

## Inputs

- `ISSUE_NUMBER`
- `ISSUE_TITLE`
- `ISSUE_BODY`
- `ISSUE_LABELS` — current labels (so you can detect continuation vs. fresh start)

## What to do

1. **Read context:**
   - `CLAUDE.md`
   - `gh issue view $ISSUE_NUMBER --comments` — find the `<!-- plan -->` comment. **If there is no plan, abort:** set `state:blocked`, comment "no plan found, returning to planner", and stop.
   - Any files the plan says it will touch
   - The PR template at `.github/pull_request_template.md`

2. **Set up the worktree.**
   - Branch name: `issue-${ISSUE_NUMBER}-$(slugify "$ISSUE_TITLE")`
   - Worktree path: `.worktrees/issue-${ISSUE_NUMBER}`
   - If the worktree exists, this is a continuation: `cd` into it and pull.
   - If not: `git worktree add .worktrees/issue-${ISSUE_NUMBER} -b <branch>` from `main`.
   - **CRITICAL: Always branch from `main`.** Never branch from another issue's branch. If the issue depends on code that hasn't landed on `main` yet, set `state:blocked` and stop — do not stack PRs on top of unmerged branches.
   - All work happens inside the worktree. Do not touch the main checkout.

3. **Set the label** (if not already): remove `state:planned`, add `state:in-progress`.

4. **Implement the plan** inside the worktree. Stay strictly within the plan's "Files to touch" / "New files to create" lists. If you discover the plan is wrong:
   - Stop coding
   - Post a comment on the issue describing what's wrong with the plan
   - Set label to `state:blocked`
   - Exit

5. **Commits.** Make small, logical commits. Conventional style:
   - `feat(catalog): add Asset model with content_hash`
   - `test(editor): snapshot test for develop view`
   - `chore(infra): wire harness smoke into CI`

6. **Run the verification ladder for everything you touched:**
   - **Layer A:** `swift test` in each affected package under `Packages/*/`
   - **Layer B:** snapshot tests if any views or edit outputs changed
   - **Layer C:** harness smoke flow if any user-facing action changed
   - All three must pass before opening the PR. If a test you added fails, fix the code, not the test.

7. **Capture screenshots** for the PR using the `capture-screenshots` skill in `.claude/skills/capture-screenshots.md`. Output goes to `.artifacts/issue-${ISSUE_NUMBER}/`.

8. **Push the branch and open the PR** (or update an existing one):
   - `git push -u origin <branch>`
   - If no PR exists for this branch: `gh pr create --base main` with the template, link `Closes #${ISSUE_NUMBER}`. **Always target `main`** — never target another feature branch.
   - If a PR exists: it auto-updates from the push. Add a `gh pr comment` summarising what changed since last push.
   - **Verify** the PR targets `main` with `gh pr view --json baseRefName -q .baseRefName`. If it doesn't, something went wrong — fix it with `gh pr edit --base main`.

9. **Attach screenshots to the PR.** Use the `capture-screenshots` skill's "attach" step. If upload fails, fall back to the orphan `artifacts/<branch>` branch (see `.claude/skills/capture-screenshots.md`).

10. **Set label to `state:in-review`.** Remove `state:in-progress`.

11. **Stop.** Do not request review. Do not merge. The reviewer prompt is a separate run.

## Rules

- **Do not skip git hooks.** No `--no-verify`, no `--no-gpg-sign`.
- **Do not amend other people's commits.** Always create new commits.
- **Do not push to `main`.** Branch only.
- **Do not modify CLAUDE.md** unless the issue is explicitly about updating it.
- **Do not change unrelated files.** No drive-by formatting, no unrequested refactors, no "while I'm here" cleanups.
- **Do not add error handling for impossible cases**, framework-internal validation, or backwards-compatibility shims for code you're writing for the first time.
- **If you get stuck** — a test you can't make pass, a build error you can't diagnose after a focused attempt, an API that doesn't behave as documented — comment on the issue describing the blocker, set label to `state:blocked`, push what you have so far, and stop. Do not retry the same failing thing in a loop.
