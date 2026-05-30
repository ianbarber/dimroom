#!/usr/bin/env bash
# harness-delta-sync-flow.sh — Layer C flow for delta sync via Drive
# changes API (#235, extended by #272 and #273).
#
# Walks the classified outcomes the change poller emits:
#   1. bootstrap — no stored page token, getStartPageToken returns one.
#   2. noChanges — steady-state poll with an empty changes list.
#   3. catalogChanged — fixture page reports a change to the file id
#      matching the cached catalog driveFileId, so the poller classifies
#      it as a remote catalog update (not a conflict, because there's
#      no last-published modifiedTime stored).
#   4. originalsChangedOnly — fixture page reports a change to a file
#      id that is not the cached catalog id and carries the dimroom
#      appProperty marker. The poller classifies it as a new original
#      on Drive (`originalsChangedOnly`); the harness asserts the
#      surfaced count and that the Library view model's remote-additions
#      badge picked it up via the `state` snapshot
#      (libraryRemoteAdditionsCount).
#   5. noChanges (filtered) — fixture page reports a change for a file
#      without the dimroom `appProperties` marker, which the poller
#      drops per #273.
#
# Drive HTTP is stubbed two ways:
#   - `DIMROOM_HARNESS_DRIVE_STUB=1` swaps in the OAuth-and-`/about`
#     stub HTTPClient so `applicationDidFinishLaunching` resolves a
#     DriveClient and wires the publisher + change poller.
#   - `DIMROOM_HARNESS_DRIVE_CHANGES_FIXTURE=<json>` swaps the live
#     `DriveChangesClient` for a fixture-driven stub that serves
#     successive pages from a JSON file.
#
# Assumes the capture-screenshots skill already built the App and CLI
# binaries.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/delta-sync}"
WORK_DIR="$REPO_ROOT/.artifacts/harness-delta-sync"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
FIXTURE_PATH="$WORK_DIR/changes-fixture.json"
SOCKET="/tmp/dimroom-harness-delta-sync-$$.sock"
APP_PID=""

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET"
}
trap cleanup EXIT

APP_BIN="$REPO_ROOT/App/.build/debug/Dimroom"
CLI_BIN="$REPO_ROOT/Packages/Harness/.build/debug/dimroom-cli"
FIXTURE_BIN="$REPO_ROOT/Packages/Harness/.build/debug/dimroom-fixture"

for bin in "$APP_BIN" "$CLI_BIN" "$FIXTURE_BIN"; do
    if [ ! -x "$bin" ]; then
        echo "ERROR: missing binary $bin — capture-screenshots skill should have built it"
        exit 1
    fi
done

take_screenshot() {
    local name="$1"
    local shot_path="$SCREENSHOT_DIR/$name.png"
    echo "=== screenshot: $name ==="
    local shot_out
    shot_out=$("$CLI_BIN" screenshot "$shot_path" --socket "$SOCKET")
    echo "$shot_out"
    if ! echo "$shot_out" | grep -q '"ok"'; then
        echo "ERROR: screenshot command did not return ok"
        exit 1
    fi
    if [ ! -f "$shot_path" ]; then
        echo "ERROR: screenshot file not created at $shot_path"
        exit 1
    fi
}

echo "=== Seeding catalog and fixture ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
"$FIXTURE_BIN" seed \
    --catalog "$CATALOG_PATH" \
    --cache "$PREVIEW_CACHE" \
    --seed-dir "$REPO_ROOT/fixtures/library-seed"

if [ ! -f "$CATALOG_PATH" ]; then
    echo "ERROR: dimroom-fixture did not produce $CATALOG_PATH"
    exit 1
fi

# Seed a *second* catalog with a different asset count so the hot-reload
# step (#259) can assert the swap took effect — same seed dir, but
# --duplicate 2 doubles every row so the asset count differs from the
# initial bootstrap. Used as the stub remote when DIMROOM_HARNESS_STUB_REMOTE_CATALOG
# points at this path.
RELOAD_CATALOG="$WORK_DIR/reload-source.sqlite"
RELOAD_PREVIEW_CACHE="$WORK_DIR/reload-previews"
"$FIXTURE_BIN" seed \
    --catalog "$RELOAD_CATALOG" \
    --cache "$RELOAD_PREVIEW_CACHE" \
    --seed-dir "$REPO_ROOT/fixtures/library-seed" \
    --duplicate 2

if [ ! -f "$RELOAD_CATALOG" ]; then
    echo "ERROR: dimroom-fixture did not produce $RELOAD_CATALOG"
    exit 1
fi

# Fixture describes the sequence of `listChanges` responses the stub
# returns. The third page reports a change to "stub-catalog-id", which
# the poller matches against the cached catalog driveFileId we'll plant
# in the file-id store below. The fourth page reports a tagged change
# to a different file id ("stub-original-id"), which the poller
# classifies as a new original on Drive (`originalsChangedOnly`). The
# fifth page reports a change for a file lacking the dimroom
# appProperty marker — the poller drops it (#273) and surfaces
# .noChanges.
cat >"$FIXTURE_PATH" <<'JSON'
{
  "startPageToken": "stub-start-token",
  "pages": [
    {
      "newStartPageToken": "stub-token-after-empty",
      "changes": []
    },
    {
      "newStartPageToken": "stub-token-after-catalog-change",
      "changes": [
        {
          "fileId": "stub-catalog-id",
          "name": "catalog.sqlite",
          "modifiedTime": "2026-05-17T08:00:00.000Z",
          "mimeType": "application/x-sqlite3",
          "parents": ["catalog-folder"],
          "removed": false,
          "trashed": false
        }
      ]
    },
    {
      "newStartPageToken": "stub-token-after-originals-change",
      "changes": [
        {
          "fileId": "stub-original-id",
          "name": "DSC_0001.jpg",
          "modifiedTime": "2026-05-17T09:00:00.000Z",
          "mimeType": "image/jpeg",
          "parents": ["digital-folder"],
          "appProperties": {"dimroom": "1"},
          "removed": false,
          "trashed": false
        }
      ]
    },
    {
      "newStartPageToken": "stub-token-after-untagged-drop",
      "changes": [
        {
          "fileId": "foreign-file-id",
          "name": "not-dimroom.jpg",
          "modifiedTime": "2026-05-18T08:00:00.000Z",
          "mimeType": "image/jpeg",
          "parents": ["some-other-folder"],
          "removed": false,
          "trashed": false
        }
      ]
    }
  ]
}
JSON

# Plant the cached catalog driveFileId before launching the app so the
# poller's conflict-detection branch can match the fixture's change
# entry. The store lives under Application Support by default; we
# overwrite to a deterministic value just for this run.
FILE_ID_PATH="${HOME}/Library/Application Support/Dimroom/drive-catalog-id.txt"
mkdir -p "$(dirname "$FILE_ID_PATH")"
PREVIOUS_FILE_ID=""
if [ -f "$FILE_ID_PATH" ]; then
    PREVIOUS_FILE_ID=$(cat "$FILE_ID_PATH")
fi
printf "stub-catalog-id" >"$FILE_ID_PATH"

restore_file_id() {
    if [ -n "$PREVIOUS_FILE_ID" ]; then
        printf "%s" "$PREVIOUS_FILE_ID" >"$FILE_ID_PATH"
    else
        rm -f "$FILE_ID_PATH"
    fi
}
trap 'cleanup; restore_file_id' EXIT

mkdir -p "$SCREENSHOT_DIR"

echo "=== Launching app in harness mode ==="
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_HARNESS_DRIVE_STUB=1 \
DIMROOM_HARNESS_DRIVE_CHANGES_FIXTURE="$FIXTURE_PATH" \
DIMROOM_HARNESS_STUB_REMOTE_CATALOG="$RELOAD_CATALOG" \
    "$APP_BIN" --harness \
    --fixture-catalog "$CATALOG_PATH" \
    --preview-cache "$PREVIEW_CACHE" &
APP_PID=$!

echo "=== Waiting for socket ==="
for i in $(seq 1 30); do
    if [ -e "$SOCKET" ]; then
        echo "Socket ready after ${i}s"
        break
    fi
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "ERROR: App exited before socket was ready"
        exit 1
    fi
    sleep 1
done
if [ ! -e "$SOCKET" ]; then
    echo "ERROR: Socket not ready after 30s"
    exit 1
fi

echo "=== connect-drive — wire up the publisher + change poller ==="
CONNECT_OUT=$("$CLI_BIN" connect-drive --socket "$SOCKET")
echo "$CONNECT_OUT"
CONNECT_STATUS=$(printf '%s' "$CONNECT_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
if [ "$CONNECT_STATUS" != "connected" ]; then
    echo "ERROR: expected drive auth status 'connected', got '$CONNECT_STATUS'"
    exit 1
fi

echo "=== sync-from-drive — bootstrap path ==="
BOOT_OUT=$("$CLI_BIN" sync-from-drive --socket "$SOCKET")
echo "$BOOT_OUT"
BOOT_STATUS=$(printf '%s' "$BOOT_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
BOOT_TOKEN=$(printf '%s' "$BOOT_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.pageToken')
if [ "$BOOT_STATUS" != "bootstrapped" ]; then
    echo "ERROR: expected first sync status 'bootstrapped', got '$BOOT_STATUS'"
    exit 1
fi
if [ "$BOOT_TOKEN" != "stub-start-token" ]; then
    echo "ERROR: expected pageToken 'stub-start-token', got '$BOOT_TOKEN'"
    exit 1
fi
echo "  OK: bootstrapped at stub-start-token"

take_screenshot "delta-sync-bootstrapped"

echo "=== sync-from-drive — steady-state, expect noChanges ==="
NOCHG_OUT=$("$CLI_BIN" sync-from-drive --socket "$SOCKET")
echo "$NOCHG_OUT"
NOCHG_STATUS=$(printf '%s' "$NOCHG_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
NOCHG_TOKEN=$(printf '%s' "$NOCHG_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.pageToken')
if [ "$NOCHG_STATUS" != "noChanges" ]; then
    echo "ERROR: expected status 'noChanges', got '$NOCHG_STATUS'"
    exit 1
fi
if [ "$NOCHG_TOKEN" != "stub-token-after-empty" ]; then
    echo "ERROR: expected pageToken 'stub-token-after-empty', got '$NOCHG_TOKEN'"
    exit 1
fi
echo "  OK: noChanges at stub-token-after-empty"

echo "=== sync-from-drive — fixture serves catalog change ==="
CCHG_OUT=$("$CLI_BIN" sync-from-drive --socket "$SOCKET")
echo "$CCHG_OUT"
CCHG_STATUS=$(printf '%s' "$CCHG_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
CCHG_FILEID=$(printf '%s' "$CCHG_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.driveFileId')
CCHG_TOKEN=$(printf '%s' "$CCHG_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.pageToken')
if [ "$CCHG_STATUS" != "catalogChanged" ]; then
    echo "ERROR: expected status 'catalogChanged', got '$CCHG_STATUS'"
    exit 1
fi
if [ "$CCHG_FILEID" != "stub-catalog-id" ]; then
    echo "ERROR: expected driveFileId 'stub-catalog-id', got '$CCHG_FILEID'"
    exit 1
fi
if [ "$CCHG_TOKEN" != "stub-token-after-catalog-change" ]; then
    echo "ERROR: expected pageToken 'stub-token-after-catalog-change', got '$CCHG_TOKEN'"
    exit 1
fi
echo "  OK: catalogChanged at stub-token-after-catalog-change"

take_screenshot "delta-sync-catalog-changed"

echo "=== sync-from-drive — fixture serves originals-only change ==="
OCHG_OUT=$("$CLI_BIN" sync-from-drive --socket "$SOCKET")
echo "$OCHG_OUT"
OCHG_STATUS=$(printf '%s' "$OCHG_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
OCHG_COUNT=$(printf '%s' "$OCHG_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.addedCount')
OCHG_TOKEN=$(printf '%s' "$OCHG_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.pageToken')
if [ "$OCHG_STATUS" != "originalsChangedOnly" ]; then
    echo "ERROR: expected status 'originalsChangedOnly', got '$OCHG_STATUS'"
    exit 1
fi
if [ "$OCHG_COUNT" != "1" ]; then
    echo "ERROR: expected addedCount '1', got '$OCHG_COUNT'"
    exit 1
fi
if [ "$OCHG_TOKEN" != "stub-token-after-originals-change" ]; then
    echo "ERROR: expected pageToken 'stub-token-after-originals-change', got '$OCHG_TOKEN'"
    exit 1
fi
echo "  OK: originalsChangedOnly at stub-token-after-originals-change"

echo "=== state — assert Library badge picked up the addedCount ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
STATE_BADGE=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.libraryRemoteAdditionsCount')
if [ "$STATE_BADGE" != "1" ]; then
    echo "ERROR: expected libraryRemoteAdditionsCount '1', got '$STATE_BADGE'"
    exit 1
fi
echo "  OK: badge surfaced 1 remote addition"

take_screenshot "delta-sync-originals-added"

echo "=== dismiss-remote-additions-badge — fire the badge's X dismiss path (#313) ==="
"$CLI_BIN" dismiss-remote-additions-badge --socket "$SOCKET"
DISMISS_STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$DISMISS_STATE_OUT"
DISMISS_BADGE=$(printf '%s' "$DISMISS_STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" --absent 'data.libraryRemoteAdditionsCount')
if [ "$DISMISS_BADGE" != "absent" ]; then
    echo "ERROR: expected libraryRemoteAdditionsCount null after dismiss, got '$DISMISS_BADGE'"
    exit 1
fi
echo "  OK: badge cleared after dismiss"

take_screenshot "delta-sync-additions-dismissed"

echo "=== sync-from-drive — fixture serves untagged change, expect filtered to noChanges (#273) ==="
DROP_OUT=$("$CLI_BIN" sync-from-drive --socket "$SOCKET")
echo "$DROP_OUT"
DROP_STATUS=$(printf '%s' "$DROP_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
DROP_TOKEN=$(printf '%s' "$DROP_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.pageToken')
if [ "$DROP_STATUS" != "noChanges" ]; then
    echo "ERROR: expected status 'noChanges' (untagged change dropped), got '$DROP_STATUS'"
    exit 1
fi
if [ "$DROP_TOKEN" != "stub-token-after-untagged-drop" ]; then
    echo "ERROR: expected pageToken 'stub-token-after-untagged-drop', got '$DROP_TOKEN'"
    exit 1
fi
echo "  OK: untagged change dropped, advanced to stub-token-after-untagged-drop"

# The reload step (#259) runs last because it rebuilds the change poller
# against the swapped catalog with a fresh HarnessStubChangesFetcher,
# whose page cursor resets — so any sync-from-drive assertion that relies
# on the fixture's page sequence (the catalogChanged / originalsChangedOnly /
# untagged-drop polls above) has to happen before the reload, not after.
echo "=== state — capture pre-reload asset count ==="
PRE_STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$PRE_STATE_OUT"
PRE_RELOAD_COUNT=$(printf '%s' "$PRE_STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.assetCount')
echo "  Pre-reload asset count: $PRE_RELOAD_COUNT"

echo "=== reload-catalog-from-drive — hot-reload the local catalog (#259) ==="
RELOAD_OUT=$("$CLI_BIN" reload-catalog-from-drive \
    --drive-file-id stub-catalog-id \
    --modified-time 2026-05-17T08:00:00.000Z \
    --page-token stub-token-after-catalog-change \
    --socket "$SOCKET")
echo "$RELOAD_OUT"
RELOAD_OUTCOME=$(printf '%s' "$RELOAD_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.outcome')
if [ "$RELOAD_OUTCOME" != "reloaded" ]; then
    echo "ERROR: expected reload outcome=reloaded, got '$RELOAD_OUTCOME'"
    exit 1
fi
echo "  OK: catalog reloaded in-place"

echo "=== state — asset count reflects new catalog, process survived ==="
if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "ERROR: app process died during reload"
    exit 1
fi
POST_STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$POST_STATE_OUT"
POST_RELOAD_COUNT=$(printf '%s' "$POST_STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.assetCount')
if [ "$POST_RELOAD_COUNT" = "$PRE_RELOAD_COUNT" ]; then
    echo "ERROR: post-reload asset count ($POST_RELOAD_COUNT) matches pre-reload ($PRE_RELOAD_COUNT) — swap didn't take"
    exit 1
fi
echo "  OK: assetCount went $PRE_RELOAD_COUNT -> $POST_RELOAD_COUNT, PID $APP_PID survived"

take_screenshot "delta-sync-after-reload"

echo "=== sync-from-drive after reload — rebuilt poller drains empty page, expect noChanges (#322) ==="
# The reload rebuilt the poller against the swapped catalog with a fresh
# HarnessStubChangesFetcher, whose page cursor reset to 0 — so this first
# post-reload poll replays the empty page 0 (noChanges, stub-token-after-empty).
# Asserting it (no `|| true`, no swallowed exit) confirms the rebuilt poller
# is wired up and responds without crashing on the new catalog.
POSTRELOAD_EMPTY_OUT=$("$CLI_BIN" sync-from-drive --socket "$SOCKET")
echo "$POSTRELOAD_EMPTY_OUT"
POSTRELOAD_EMPTY_STATUS=$(printf '%s' "$POSTRELOAD_EMPTY_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
POSTRELOAD_EMPTY_TOKEN=$(printf '%s' "$POSTRELOAD_EMPTY_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.pageToken')
if [ "$POSTRELOAD_EMPTY_STATUS" != "noChanges" ]; then
    echo "ERROR: expected post-reload status 'noChanges', got '$POSTRELOAD_EMPTY_STATUS'"
    exit 1
fi
if [ "$POSTRELOAD_EMPTY_TOKEN" != "stub-token-after-empty" ]; then
    echo "ERROR: expected post-reload pageToken 'stub-token-after-empty', got '$POSTRELOAD_EMPTY_TOKEN'"
    exit 1
fi
echo "  OK: noChanges at stub-token-after-empty (rebuilt poller responds)"

echo "=== sync-from-drive after reload — replayed catalog change matches stamp, expect noChanges (#322) ==="
# The second post-reload poll replays page 1 — the catalog-change row for
# stub-catalog-id carrying modifiedTime 2026-05-17T08:00:00.000Z, the exact
# value CatalogHotReloader stamped into last_published_catalog_modified_time
# during the swap. Because the stamp matches, the rebuilt poller MUST classify
# this replayed change as noChanges (not catalogChanged, not an error) — the
# end-to-end "don't re-prompt for state we already have" guarantee from #259,
# pinned here so a regression in how the stamp is carried onto the reloaded
# catalog can't drift undetected. Asserting pageToken proves the catalog-change
# page was the one processed, not a second empty page.
POSTRELOAD_REPLAY_OUT=$("$CLI_BIN" sync-from-drive --socket "$SOCKET")
echo "$POSTRELOAD_REPLAY_OUT"
POSTRELOAD_REPLAY_STATUS=$(printf '%s' "$POSTRELOAD_REPLAY_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
POSTRELOAD_REPLAY_TOKEN=$(printf '%s' "$POSTRELOAD_REPLAY_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.pageToken')
if [ "$POSTRELOAD_REPLAY_STATUS" != "noChanges" ]; then
    echo "ERROR: expected replayed catalog-change status 'noChanges' (stamp match), got '$POSTRELOAD_REPLAY_STATUS'"
    exit 1
fi
if [ "$POSTRELOAD_REPLAY_TOKEN" != "stub-token-after-catalog-change" ]; then
    echo "ERROR: expected replayed catalog-change pageToken 'stub-token-after-catalog-change', got '$POSTRELOAD_REPLAY_TOKEN'"
    exit 1
fi
echo "  OK: replayed catalog change classified noChanges at stub-token-after-catalog-change (stamp pinned end-to-end)"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness delta-sync flow PASSED ==="
