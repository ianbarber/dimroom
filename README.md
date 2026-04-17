# dimroom

A native macOS photo editing and management app for digital captures and film scans, with Google Drive as primary storage.

Personal project. Not accepting contributions. Built with an agent-driven workflow ([CLAUDE.md](CLAUDE.md)).

## What it does (target)

- Imports from cameras and folders, organises by date, tags source as digital or film scan
- Browses a Drive-resident library without keeping a full local mirror
- Fast keyboard-driven culling: 1–5 star ratings, filters, rotation
- Non-destructive develop view: crop, white balance, exposure, contrast, clarity, vibrance, basic colour, perspective
- Copy-paste edit settings across selections
- Export to local folder and/or Drive

## Status

Stage 0 — agent loop and verification skeleton. Nothing user-facing yet. See [delivery stages](#delivery-stages).

## Architecture

The app target is a thin SwiftUI shell. Almost everything lives in independently-testable SPM packages under `Packages/`:

- `Catalog` — SQLite (GRDB.swift)
- `ImportKit` — sources, dedup, EXIF, staging
- `Previews` — thumbnail/preview generation
- `EditEngine` — Core Image filter graph + `EditState` Codable model
- `DriveClient` — Google Drive REST v3, OAuth PKCE
- `SyncEngine` — local⇄Drive reconciliation
- `Harness` — local socket control surface for agent verification

Full architectural rules in [CLAUDE.md](CLAUDE.md).

## Verification

Three layers:

- **A.** `swift test` per package — pure logic, headless, fast
- **B.** Snapshot tests via `pointfreeco/swift-snapshot-testing` — views and edit-engine outputs as PNGs vs. goldens
- **C.** Harness smoke flows — app launched in `--harness` mode against the fixture catalog, driven over a local socket, screenshots written to `.artifacts/<branch>/`

If a feature isn't reachable through the harness, it isn't done.

## Delivery stages

- **Stage 0** — Skeleton: repo, CI, agent loop, harness shell, fixtures, snapshot infra, screenshot pipeline
- **Stage 1** — Catalog + Import (local only)
- **Stage 2** — Gallery + Loupe view, ratings, filtering, rotation
- **Stage 3** — Develop view + EditEngine (basic tools), copy/paste settings
- **Stage 4** — Export
- **Stage 5** — Drive integration (OAuth, upload, fetch on demand)
- **Stage 6** — Sync engine
- **Stage 7** — Advanced edit tools (NR, colour balance, perspective)
- **Stage 8** — NAS archive

## Icon / bundle

`bin/build-icon.sh` regenerates the app icon from the Core Graphics renderer in `Packages/AppIcon`. `bin/build-app-bundle.sh` wraps the built executable into a `Dimroom.app` bundle with the icon for Finder.

## Agent loop

```sh
bin/agent-loop.sh           # one pass: pick next issue, run matching prompt
bin/agent-loop.sh --watch   # loop forever
```

The loop picks issues by `state:*` label precedence (`changes-requested` > `in-review` > `in-progress` > `planned` > `needs-plan`), spawns a clean Claude Code session with the matching prompt in `.claude/prompts/`, and stops. It does not merge PRs — that's the human's job.

## Requirements

- macOS 14+
- Xcode 15+ (full Xcode, not just Command Line Tools — needed once we add the app target in Stage 0.3)
- Swift 6.0+
- `gh` CLI authenticated against the repo
- Google Drive account (for Stage 5+)

## Licence

All rights reserved. Personal project.
