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
   - If the worktree exists, this is a continuation: `cd` into it and pull. **Then resume from the checkpoint** — see "Progress checkpoints & context handoff" below: run `bin/agent-checkpoint.sh phase .` and skip the milestones already done (a `pr-opened` checkpoint means the PR exists; pick up at whatever the recorded phase implies is next). Also check `git log origin/main..HEAD` — a prior pass may have already committed and pushed work.
   - If not: `git worktree add .worktrees/issue-${ISSUE_NUMBER} -b <branch>` from `main`.
   - **CRITICAL: Always branch from `main`.** Never branch from another issue's branch. If the issue depends on code that hasn't landed on `main` yet, set `state:blocked` and stop — do not stack PRs on top of unmerged branches.
   - All work happens inside the worktree. Do not touch the main checkout.
   - Once the worktree exists, write the first checkpoint: `bin/agent-checkpoint.sh write . branch-created "worktree + branch ready"`.

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

   Once the implementation is committed, checkpoint it: `bin/agent-checkpoint.sh write . code-written "<what's done / what's left>" "$(git rev-parse HEAD)"`.

6. **Run the verification ladder for everything you touched:**
   - **App build:** `swift build --package-path App` must succeed. This is mandatory even if you only touched packages — the App target imports all packages and may fail on API changes that package-level `swift test` misses.
   - **Layer A:** `swift test` in each affected package under `Packages/*/`
   - **Layer B:** snapshot tests if any views or edit outputs changed
   - **Layer C:** harness smoke flow if any user-facing action changed
   - All four must pass before opening the PR. If a test you added fails, fix the code, not the test.

   When the ladder is green, checkpoint it: `bin/agent-checkpoint.sh write . tests-passing "ladder green" "$(git rev-parse HEAD)"`.

7. **Capture screenshots** for the PR using the `capture-screenshots` skill in `.claude/skills/capture-screenshots.md`. Output goes to `.artifacts/issue-${ISSUE_NUMBER}/`.

8. **Push the branch and open the PR** (or update an existing one):
   - `git push -u origin <branch>`
   - If no PR exists for this branch: `gh pr create --base main` with the template, link `Closes #${ISSUE_NUMBER}`. **Always target `main`** — never target another feature branch.
   - If a PR exists: it auto-updates from the push. Add a `gh pr comment` summarising what changed since last push.
   - **Verify** the PR targets `main` with `gh pr view --json baseRefName -q .baseRefName`. If it doesn't, something went wrong — fix it with `gh pr edit --base main`.
   - Once the PR is open, checkpoint it: `bin/agent-checkpoint.sh write . pr-opened "PR open, awaiting screenshots + label" "$(git rev-parse HEAD)"`.

9. **Attach screenshots to the PR.** Use the `capture-screenshots` skill's "attach" step. If upload fails, fall back to the orphan `artifacts/<branch>` branch (see `.claude/skills/capture-screenshots.md`).

10. **Set label to `state:in-review`.** Remove `state:in-progress`.

11. **Stop.** Do not request review. Do not merge. The reviewer prompt is a separate run.

## Progress checkpoints & context handoff

A run can die mid-stage — a socket error, an API outage, or the per-session timeout (#374). Without a breadcrumb the next loop pass re-reads the issue and starts over, throwing away whatever the prior session built. To avoid that, this stage checkpoints its progress to `.agent-state.json` in the worktree.

- **The helper:** `bin/agent-checkpoint.sh write <dir> <phase> "<notes>" [sha]` writes the checkpoint atomically; `bin/agent-checkpoint.sh phase <dir>` prints just the recorded phase. Run them with `<dir>` = `.` from inside the worktree. The file is gitignored, so it never lands in the PR.
- **Milestones** (write one as you pass each, as noted in the steps above): `branch-created` → `code-written` → `tests-passing` → `pr-opened`. Each records the phase, the last commit SHA, and free-form notes on what's done and what's left.
- **Resuming:** on a continuation, read the checkpoint first (`bin/agent-checkpoint.sh phase .`) and skip the milestones already reached. Phases already visible in git/GitHub (branch exists, commits pushed, PR open, label moved) are idempotent observations you can re-derive directly — the checkpoint's job is the finer-grained "I'm partway through the Layer C flow" notes. Trust the worktree's actual state over the checkpoint if they disagree.

**If you find you've used substantial context and still have a lot of work left, do NOT try to finish in one session** — degraded reasoning or an opaque context-limit failure is worse than a clean handoff. Instead:

1. Write the current state: `bin/agent-checkpoint.sh write . <phase> "<what's done, what's left, any gotchas>" "$(git rev-parse HEAD)"`.
2. Commit and push what you have with a WIP message (`wip(area): <summary> — handoff, see .agent-state.json`).
3. Make sure the label is `state:in-progress` (the next pass is another implementer continuation).
4. Exit with a brief summary of what's done and what's left. The next loop pass resumes from the checkpoint.

## Rules

- **Do not skip git hooks.** No `--no-verify`, no `--no-gpg-sign`.
- **Do not amend other people's commits.** Always create new commits.
- **Do not push to `main`.** Branch only.
- **Do not modify CLAUDE.md** unless the issue is explicitly about updating it.
- **Do not change unrelated files.** No drive-by formatting, no unrequested refactors, no "while I'm here" cleanups.
- **Do not add error handling for impossible cases**, framework-internal validation, or backwards-compatibility shims for code you're writing for the first time.
- **If you get stuck** — a test you can't make pass, a build error you can't diagnose after a focused attempt, an API that doesn't behave as documented — comment on the issue describing the blocker, set label to `state:blocked`, push what you have so far, and stop. Do not retry the same failing thing in a loop.
