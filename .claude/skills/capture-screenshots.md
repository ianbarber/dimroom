# Skill: capture-screenshots

Capture harness screenshots for a PR and attach them to the PR for review.

## When to use

- During the IMPLEMENT stage, after tests pass, before opening the PR
- During the RESPOND stage, if any UI-affecting change was made
- Anywhere a stage prompt says "use the capture-screenshots skill"

## Inputs

- `ISSUE_NUMBER` — used as the artifact directory name
- `BRANCH` — current git branch
- `FLOWS` — newline-separated list of flow shell scripts. Defaults to every `bin/harness-*-flow.sh` the plan / test plan mentions, or every existing `bin/harness-*-flow.sh` if the plan doesn't enumerate them.

## What a "flow" is

A flow is a **self-contained shell script** under `bin/` named `bin/harness-<name>-flow.sh`, modeled on `bin/harness-smoke.sh`. There is no JSON flow runner — the script *is* the flow.

Each flow script must:

1. Assume the binaries already exist at `App/.build/debug/Dimroom` and `Packages/Harness/.build/debug/dimroom-cli` (the capture skill builds them in step 1; flow scripts must not rebuild).
2. Launch the app via that binary with `--harness` and a fixture catalog.
3. Wait for the harness socket.
4. Send commands via `dimroom-cli`.
5. Write all screenshots into the directory named by `$SCREENSHOT_DIR` (env var, mandatory — the capture skill sets it per-flow).
6. Quit the app and clean up its socket.
7. Exit 0 on success, non-zero on any failure.

`bin/harness-smoke.sh` is the canonical template — copy it and adapt the command sequence.

## Steps

### 1. Build the app and CLI

```bash
swift build --package-path App
swift build --package-path Packages/Harness --product dimroom-cli
```

If either build fails, abort screenshot capture and post a `gh pr comment` noting the build failure with the last ~20 lines of build output.

### 2. Run each flow

```bash
mkdir -p ".artifacts/issue-${ISSUE_NUMBER}"

# Default to every harness-*-flow.sh if FLOWS is unset.
if [ -z "${FLOWS:-}" ]; then
  FLOWS=$(ls bin/harness-*-flow.sh 2>/dev/null || true)
fi

for FLOW in $FLOWS; do
  NAME=$(basename "$FLOW" .sh)        # harness-import-flow
  NAME="${NAME#harness-}"             # import-flow
  NAME="${NAME%-flow}"                # import

  OUT=".artifacts/issue-${ISSUE_NUMBER}/${NAME}"
  mkdir -p "$OUT"

  echo "=== running $FLOW (out: $OUT) ==="
  if ! SCREENSHOT_DIR="$OUT" bash "$FLOW"; then
    echo "WARN: flow $FLOW exited non-zero; continuing with remaining flows"
  fi
done
```

A flow exiting non-zero is logged but does not abort the capture step — partial screenshots are better than none.

### 3. Generate a contact sheet (optional, only if `magick` is on PATH)

```bash
if command -v magick >/dev/null 2>&1; then
  shopt -s globstar nullglob
  PNGS=( .artifacts/issue-${ISSUE_NUMBER}/**/*.png )
  if [ ${#PNGS[@]} -gt 0 ]; then
    magick montage "${PNGS[@]}" \
      -tile 4x -geometry 480x270+8+8 \
      ".artifacts/issue-${ISSUE_NUMBER}/contact-sheet.png"
  fi
fi
```

### 4. Attach to the PR — primary path

GitHub PR comments accept image uploads. `gh pr comment` will upload local files referenced in markdown and rewrite the URLs to `https://github.com/user-attachments/...`.

```bash
PR_NUMBER=$(gh pr view --json number -q .number)

shopt -s globstar nullglob
PNGS=( .artifacts/issue-${ISSUE_NUMBER}/**/*.png )

if [ ${#PNGS[@]} -eq 0 ]; then
  # No screenshots — see "No-UI escape hatch" below.
  exit 0
fi

{
  echo "## Screenshots for $(git rev-parse --short HEAD)"
  echo
  for img in "${PNGS[@]}"; do
    rel="${img#.artifacts/issue-${ISSUE_NUMBER}/}"
    echo "### ${rel}"
    echo
    echo "![](${img})"
    echo
  done
} > /tmp/screenshot-comment.md

gh pr comment "$PR_NUMBER" --body-file /tmp/screenshot-comment.md
```

Verify by re-fetching: `gh pr view "$PR_NUMBER" --comments`. The image references should now point to `https://github.com/user-attachments/...`. If they still point to local paths, the upload silently failed — fall through to step 5.

### 5. Fallback path — orphan artifacts branch

If the upload didn't rewrite to `user-attachments` (uploads silently failed, common for large files or rate limits), use this fallback:

```bash
ARTIFACT_BRANCH="artifacts/$BRANCH"
git fetch origin "$ARTIFACT_BRANCH" 2>/dev/null || true

TMP_WT=$(mktemp -d)
if git show-ref --quiet "refs/remotes/origin/$ARTIFACT_BRANCH"; then
  git worktree add "$TMP_WT" "$ARTIFACT_BRANCH"
else
  git worktree add --orphan "$TMP_WT" "$ARTIFACT_BRANCH"
  (cd "$TMP_WT" && git rm -rf . 2>/dev/null || true)
fi

mkdir -p "$TMP_WT/issue-${ISSUE_NUMBER}"
cp -R ".artifacts/issue-${ISSUE_NUMBER}"/* "$TMP_WT/issue-${ISSUE_NUMBER}/"

(cd "$TMP_WT" && \
  git add . && \
  git commit -m "screenshots: $(git -C "$OLDPWD" rev-parse --short HEAD)" && \
  git push -u origin "$ARTIFACT_BRANCH")

git worktree remove "$TMP_WT"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
COMMIT=$(git ls-remote origin "$ARTIFACT_BRANCH" | cut -f1)
gh pr comment "$PR_NUMBER" --body "Screenshots (fallback to orphan branch \`$ARTIFACT_BRANCH\`): https://github.com/$REPO/tree/$COMMIT/issue-${ISSUE_NUMBER}"
```

The orphan branch is named `artifacts/<branch>`, parallel to the source branch, so the `cleanup-artifacts` skill can find it by convention.

## No-UI escape hatch

Some PRs (pure logic packages, tooling, schema migrations) have nothing visual to screenshot. If the issue's plan does not name any flow scripts AND there are no `bin/harness-*-flow.sh` scripts touched by the PR, write a placeholder and post a one-line PR comment instead of running anything:

```bash
mkdir -p ".artifacts/issue-${ISSUE_NUMBER}"
cat > ".artifacts/issue-${ISSUE_NUMBER}/NO-SCREENSHOTS.txt" <<EOF
This PR has no UI-affecting changes; no harness flows were run.
EOF
gh pr comment "$PR_NUMBER" --body "_No screenshots: this PR has no UI-affecting changes._"
```

## Notes

- `.artifacts/` is gitignored — never commit it on the working branch.
- Don't spend more than two minutes attempting the primary attach path before falling back.
- Flow scripts must NOT rebuild — the capture skill builds once in step 1 and assumes the binaries are present for every flow.
- If you find yourself wanting a "flow runner" or a JSON flow format, stop. The shell-script convention is deliberate. Add new shell scripts; do not invent abstractions.
