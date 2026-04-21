# dimroom

A native macOS photo editing and management app for digital captures and film scans, with Google Drive as primary storage.

**You should probably use [darktable](https://www.darktable.org/) instead.** It's mature, cross-platform, open-source, and has a vastly larger feature set. dimroom is a personal experiment — a single-user app built almost entirely by an [autonomous agent loop](CLAUDE.md) to explore what that workflow looks like in practice. It works for its author's narrow use case but is not a general-purpose tool.

## What it does

- Imports from cameras and folders, organises by date, groups by import session
- Browses a Drive-resident library without keeping a full local mirror (originals fetched on demand, LRU-cached)
- Fast keyboard-driven culling: 1–5 star ratings, filters, rotation, multi-select + delete
- Non-destructive develop view: crop, white balance, exposure, contrast, highlights, shadows, clarity, vibrance, saturation
- Copy-paste edit settings across selections
- Pinch-to-zoom in Loupe with pan + zoom indicator
- Export to local folder (original or with edits baked in)
- Google Drive integration: OAuth PKCE, upload originals, fetch on demand

## How it was built

This project is built with an agent-driven workflow. A [dispatch loop](bin/agent-loop.sh) picks GitHub issues by state-label precedence, spawns a Claude Code session with the matching [prompt](.claude/prompts/), and progresses each issue through plan → implement → review → ready-to-merge. The human merges; the loop continues. Three loops run in parallel (planner, implementer, reviewer) for throughput.

The rules, architecture, and conventions are in [CLAUDE.md](CLAUDE.md). The agent loop infrastructure — prompts, skills, label state machine, verification ladder, screenshot capture — may be the most reusable part of this repo if you're interested in autonomous coding workflows.

## Architecture

The app target is a thin SwiftUI shell. Almost everything lives in independently-testable SPM packages under `Packages/`:

| Package | Purpose |
|---|---|
| `Catalog` | SQLite via GRDB.swift — assets, edits, ratings, collections |
| `ImportKit` | Folder source, SHA-256 dedup, EXIF extraction, staging |
| `Previews` | Thumbnail (256px) + preview (2048px) generation, on-disk cache |
| `EditEngine` | Core Image filter graph, applies `EditState` to produce rendered output |
| `DriveClient` | Google Drive REST v3, OAuth PKCE, resumable upload, LRU originals cache |
| `UI` | SwiftUI views — Library grid, Loupe, Develop, navigation, overlays |
| `Harness` | Unix socket control surface for agent-driven verification |

## Verification

Three layers, in order of fidelity:

- **A.** `swift test` per package — pure logic, headless, fast
- **B.** Snapshot tests via `pointfreeco/swift-snapshot-testing` — views and edit-engine outputs as PNGs vs. goldens
- **C.** Harness smoke flows — app launched in `--harness` mode against a fixture catalog, driven over a local socket

If a feature isn't reachable through the harness, it isn't done.

## Quick start

```sh
make build   # clean + build
make run     # clean + build + launch
make test    # run all package tests
```

### Google Drive setup (optional)

1. Create a Google Cloud project with the Drive API enabled
2. Create an OAuth Desktop client ID
3. Write credentials to `~/Library/Application Support/Dimroom/oauth.json`:
   ```json
   {
     "client_id": "YOUR_CLIENT_ID.apps.googleusercontent.com",
     "client_secret": "YOUR_CLIENT_SECRET"
   }
   ```

## Requirements

- macOS 14+
- Xcode 15+ (full Xcode, not just Command Line Tools)
- Swift 6.0+
- `gh` CLI authenticated against the repo (for the agent loop)
- Google Drive account (optional, for cloud backup)

## Agent loop

```sh
# Single-threaded (one issue at a time):
bin/agent-loop.sh --watch

# Parallel (plan + implement + review concurrently):
bin/agent-loop.sh --watch --planner-only &
bin/agent-loop.sh --watch --implementer-only &
bin/agent-loop.sh --watch --reviewer-only &
```

The loop picks issues by `state:*` label precedence, spawns a clean Claude Code session with the matching prompt, and stops at `state:ready-to-merge`. It does not merge PRs — that's the human's job.

## Licence

This project is licensed under the [GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.en.html) — see [LICENSE](LICENSE) for the full text.
