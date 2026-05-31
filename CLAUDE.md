# Dimroom — project guidance for Claude

This file is loaded into every agent session that touches this repo. Read it before doing anything else.

## What dimroom is

A native macOS photo editing and management app in the Lightroom / Capture One mold, tailored to one user's workflow that mixes digital camera imports and film negative scans, with Google Drive as primary storage.

Not Lightroom. Smaller surface, opinionated. The tools that exist must work well; missing tools are a feature.

## Hard rules

These are not preferences. Do not relax them without an explicit instruction from the user in the current conversation.

1. **macOS-only.** No iOS, no iPadOS, no Catalyst.
2. **Non-destructive editing only.** Originals are never modified. Edits live in the catalog as a versioned `EditState` document.
3. **No full local mirror.** Originals live in Google Drive. Locally we keep previews always, originals on demand (LRU cache).
4. **Every user-facing action must be reachable through the harness control surface.** If a feature is not scriptable, it is not done. There is no parallel test code path — the harness sends the same `Command` values the UI does.
5. **Do not bake credentials, tokens, or personal photo paths into the repo.** Refresh tokens go in the Keychain. Test fixtures go in `fixtures/`.
6. **Do not merge your own PRs.** When a PR is approved and CI is green, tag `@ianbarber` and stop.
7. **Do not skip Git hooks** (`--no-verify`, `--no-gpg-sign`, etc.) unless the user explicitly asks for it in the current conversation.

## Architecture at a glance

```
PhotoToolApp (Xcode app target, SwiftUI)
  └── consumes ──┐
                 ▼
SPM packages (each independently testable, headless)
  Catalog       — SQLite via GRDB.swift; assets, edits, ratings, collections
  ImportKit     — sources (ImageCaptureCore + folder), dedup by SHA-256, EXIF, staging
  Previews      — thumbnail/preview generation; one decode per asset
  EditEngine    — Core Image filter graph + EditState Codable struct
  DriveClient   — Google Drive REST v3 (no SDK), OAuth PKCE, resumable upload
  SyncEngine    — local⇄Drive reconciliation, change tokens
  Harness       — local socket control surface, fixture catalog loader
```

The app target is thin. Almost everything lives in packages so it can be tested without the GUI.

## Project layout (target shape — fill in as we build)

```
.
├── CLAUDE.md                  # this file
├── README.md
├── .gitignore
├── .github/
│   ├── ISSUE_TEMPLATE/
│   ├── pull_request_template.md
│   └── workflows/
│       ├── ci.yml             # swift test + build + harness smoke
│       └── labels.yml         # sync labels from labels.json
├── .claude/
│   ├── prompts/               # one-shot prompts for the agent loop
│   ├── skills/                # reusable instructions
│   └── fixtures/              # tiny test catalog used by harness
├── bin/
│   ├── agent-loop.sh          # dispatcher
│   └── ...
├── Packages/                  # SPM packages
│   ├── Catalog/
│   ├── ImportKit/
│   ├── Previews/
│   ├── EditEngine/
│   ├── DriveClient/
│   ├── SyncEngine/
│   └── Harness/
├── App/
│   └── Dimroom.xcodeproj      # macOS app target (Stage 0.3)
├── labels.json                # GitHub label definitions
└── .artifacts/                # gitignored, branch-scoped screenshot output
```

## Decisions already made

These are not up for re-litigation in casual tasks. If you find yourself wanting to change one, stop and ask the user.

- **Storage backend:** SQLite via GRDB.swift. Not SwiftData, not Core Data.
- **RAW decoding:** Core Image's `CIRAWFilter`. We do not write a RAW decoder.
- **Edit pipeline:** Core Image filter graph, GPU-backed. Same renderer for preview and export.
- **Drive auth:** OAuth 2.0 PKCE, scope `drive` (full), refresh token in Keychain.
- **Drive layout:** user-visible at `/PhotoTool/library/YYYY/YYYY-MM-DD/{digital,scans}/`. Catalog at `/PhotoTool/catalog/catalog.sqlite`.
- **Catalog publish:** auto-publish to Drive, no manual button.
- **Edit copy/paste:** `Cmd+C` / `Cmd+V` excludes crop and orientation by default. `Cmd+Shift+V` includes them.
- **Mode switch keys:** `G` Library, `E` Loupe, `D` Develop. Lightroom-style.
- **Snapshot tests:** `pointfreeco/swift-snapshot-testing`.
- **Screenshot delivery for PRs:** prefer `gh pr comment` with image upload; fall back to an orphan `artifacts/<branch>` branch if uploads prove flaky.
- **Dark-theme control contrast:** the app's surfaces are hardcoded dark (`Color(white: 0.05…0.12)`); there is no light mode. System-styled controls (`.segmented`/`.menu` `Picker`, borderless `Menu`) render their labels through the AppKit control foreground path, which ignores `.foregroundStyle` and so shows near-black text on the dark background — the recurring bug class of #74/#241/#319/#325. When adding such a control, apply the shared `.darkThemeControl()` modifier (`Packages/UI/Sources/UI/DarkTheme.swift`), which forces `.colorScheme(.dark)` so the system supplies a light label. For a `.bordered` `Button` carrying a custom dark `.tint`, that lever does not help — pin `.foregroundStyle(.white)` on the label's children instead (see `DevelopView.cropToggle`). Because the regression only manifests in live AppKit rendering, the load-bearing guard is a ViewInspector structural test asserting the modifier stays attached, not an offline snapshot.

## Verification ladder

Three layers, in order of fidelity. Every change must maintain or extend the layer it touches.

- **Layer A — pure logic tests** (`swift test` per package). Catalog queries, edit serialization, EXIF parsing, Drive request shaping. No UI. Fast.
- **Layer B — render/snapshot tests.** SwiftUI views and edit-engine outputs rendered to PNG and diffed against goldens. Tolerated diff is small.
- **Layer C — harness smoke flows.** App launched in `--harness` mode against the fixture catalog, driven by JSON commands over a local socket, screenshots written to `.artifacts/<branch>/`. Same `Command` enum as the UI.

When adding a feature: add a Layer A test if there's logic, a Layer B snapshot if there's a view, and a Layer C harness flow if there's a user action.

## Branch / PR conventions

- Branch: `issue-{number}-{kebab-slug}`
- One PR per issue. Small PRs preferred.
- PR title: `[#{number}] {short title}`
- PR body uses the template — fill in summary, screenshots, test plan, acceptance criteria checklist.
- Worktrees live under `.worktrees/issue-{number}/` so multiple issues can be in flight.
- Commits should be focused and reviewable. Squash on merge.

## Issue label state machine

A single `state:*` label tracks where an issue is in the loop. Exactly one state label at a time.

| Label | Meaning | Next stage |
|---|---|---|
| `state:needs-plan` | issue exists, no plan yet | planner |
| `state:planned` | plan posted as `<!-- plan -->` comment | implementer |
| `state:in-progress` | branch open, work happening | implementer (continuation) |
| `state:in-review` | PR open, awaiting review | reviewer |
| `state:changes-requested` | review left feedback | responder |
| `state:ready-to-merge` | approved, awaiting human merge | (human) |
| `state:blocked` | needs user input | (human) |

Topic labels: `area:catalog`, `area:import`, `area:editor`, `area:drive`, `area:sync`, `area:ui`, `area:harness`, `area:infra`. One or more per issue.

Stage labels: `stage:0` through `stage:8`. Exactly one per issue, matching the delivery plan in README.

## How the agent loop runs

`bin/agent-loop.sh` picks the next issue based on label state precedence (changes-requested > in-review > in-progress > planned > needs-plan) and invokes Claude Code in headless mode with the matching prompt from `.claude/prompts/`. Each invocation is a clean session — no memory of prior runs except what's in the repo, the issue, and the PR.

If you are running inside the loop, your prompt tells you what stage you are in. Stick to that stage. Do not plan and implement in the same run.

## When in doubt

- Read this file again.
- Check `.claude/prompts/` for the prompt corresponding to your stage.
- Check the issue body and any `<!-- plan -->` comment.
- If still unclear: comment on the issue with a question, set label to `state:blocked`, and stop.
