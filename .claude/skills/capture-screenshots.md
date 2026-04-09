# Skill: capture-screenshots

Capture harness screenshots for a PR and attach them to the PR for review.

## When to use

- During the IMPLEMENT stage, after tests pass, before opening the PR
- During the RESPOND stage, if any UI-affecting change was made
- Anywhere a stage prompt says "use the capture-screenshots skill"

## Inputs

- `ISSUE_NUMBER` — used as the artifact directory name
- `BRANCH` — current git branch
- `FLOWS` — newline-separated list of harness flow files to run (defaults: every `*.flow.json` mentioned in the PR's test plan)

## Steps

### 1. Build the app in harness mode

```bash
# From the worktree root.
xcodebuild \
  -project App/Dimroom.xcodeproj \
  -scheme Dimroom \
  -configuration Debug \
  -derivedDataPath .build/xcode \
  build
```

If the app target doesn't exist yet (Stage 0.3 hasn't landed), this skill is a no-op for now — write a placeholder file `.artifacts/issue-${ISSUE_NUMBER}/PLACEHOLDER.txt` explaining that screenshot capture is gated on Stage 0.3.

### 2. Run the harness for each flow

```bash
mkdir -p .artifacts/issue-${ISSUE_NUMBER}
APP_BIN=".build/xcode/Build/Products/Debug/Dimroom.app/Contents/MacOS/Dimroom"

for FLOW in $FLOWS; do
  NAME=$(basename "$FLOW" .flow.json)
  "$APP_BIN" --harness \
    --fixture-catalog .claude/fixtures/test-catalog \
    --flow "$FLOW" \
    --output-dir ".artifacts/issue-${ISSUE_NUMBER}/$NAME"
done
```

The harness writes one PNG per `screenshot` command in the flow, plus a `flow.log` and `state.json` snapshot at the end.

### 3. Generate a contact sheet (optional but useful)

```bash
if command -v magick >/dev/null; then
  magick montage \
    .artifacts/issue-${ISSUE_NUMBER}/**/*.png \
    -tile 4x -geometry 480x270+8+8 \
    .artifacts/issue-${ISSUE_NUMBER}/contact-sheet.png
fi
```

### 4. Attach to the PR — primary path

GitHub PR comments accept image uploads. Use `gh pr comment` with markdown that references local files; `gh` will upload them for you and rewrite the URLs.

```bash
PR_NUMBER=$(gh pr view --json number -q .number)
{
  echo "## Screenshots for $(git rev-parse --short HEAD)"
  echo
  for img in .artifacts/issue-${ISSUE_NUMBER}/**/*.png; do
    echo "### $(basename "$(dirname "$img")")/$(basename "$img")"
    echo
    echo "![](${img})"
    echo
  done
} > /tmp/screenshot-comment.md

gh pr comment "$PR_NUMBER" --body-file /tmp/screenshot-comment.md
```

Verify the comment by re-fetching it: `gh pr view "$PR_NUMBER" --comments`. The image references should now point to `https://github.com/user-attachments/...`.

### 5. Fallback path — orphan artifacts branch

If the upload didn't rewrite to `user-attachments` (uploads silently failed, common for large files or rate limits), use this fallback:

```bash
ARTIFACT_BRANCH="artifacts/$BRANCH"
git fetch origin "$ARTIFACT_BRANCH" 2>/dev/null || true

# Create or check out the orphan branch in a temporary worktree.
TMP_WT=$(mktemp -d)
if git show-ref --quiet "refs/remotes/origin/$ARTIFACT_BRANCH"; then
  git worktree add "$TMP_WT" "$ARTIFACT_BRANCH"
else
  git worktree add --orphan "$TMP_WT" "$ARTIFACT_BRANCH"
  (cd "$TMP_WT" && git rm -rf . 2>/dev/null || true)
fi

# Copy artifacts in.
mkdir -p "$TMP_WT/issue-${ISSUE_NUMBER}"
cp -R .artifacts/issue-${ISSUE_NUMBER}/* "$TMP_WT/issue-${ISSUE_NUMBER}/"

# Commit and push.
(cd "$TMP_WT" && \
  git add . && \
  git commit -m "screenshots: $(git -C "$OLDPWD" rev-parse --short HEAD)" && \
  git push -u origin "$ARTIFACT_BRANCH")

git worktree remove "$TMP_WT"

# Post a PR comment linking to the artifacts branch directory.
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
COMMIT=$(git ls-remote origin "$ARTIFACT_BRANCH" | cut -f1)
gh pr comment "$PR_NUMBER" --body "Screenshots (fallback to orphan branch \`$ARTIFACT_BRANCH\`): https://github.com/$REPO/tree/$COMMIT/issue-${ISSUE_NUMBER}"
```

The orphan branch is named `artifacts/<branch>`, parallel to the source branch, so cleanup-artifacts can find it by convention.

## Notes

- `.artifacts/` is gitignored — never commit it on the working branch.
- If Stage 0.3 hasn't landed and there is no app binary to run, write the placeholder and leave a note in the PR comment.
- Don't spend more than two minutes attempting the primary path before falling back.
