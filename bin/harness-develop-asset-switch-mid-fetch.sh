#!/usr/bin/env bash
# harness-develop-asset-switch-mid-fetch.sh — Layer C regression for the
# Develop "stuck download overlay" bug fixed in #204.
#
# Seeds a catalog with a Drive-only asset (A, no localPath, has
# driveFileId) and a local-file asset (B, normal seed jpeg). Activates
# Develop on A using the `hold-until-released` stub downloader so A's
# fetch parks indefinitely. Then switches to B via `set-edit-parameter`,
# which is the auto-activate path that originally exposed the bug
# (HarnessController.handleSetEditParameter → developViewModel.activate →
# fetchOriginalIfNeeded re-entry). Asserts immediately that Develop has
# cleared `isDownloadingOriginal` and `downloadProgress` — no sleep, no
# polling, because #204 was about *immediate* stale state, not a race.
#
# Finally drains A's parked download via `release-held-downloads` and
# verifies the late tail doesn't reset Develop's flag for B (proves the
# `currentAssetId == assetId` gate inside fetchOriginalIfNeeded's
# completion still holds).
#
# Expected failure mode if #204 is reverted: step 5's assertion of
# `developIsDownloadingOriginal == false` fires; the value remains `true`
# because A's task is parked and B doesn't re-enter the cancel-and-reset
# block of fetchOriginalIfNeeded.
#
# Run locally with:
#   bin/harness-develop-asset-switch-mid-fetch.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/develop-asset-switch}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-develop-asset-switch"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-develop-asset-switch-$$.sock"
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

echo "=== Seeding catalog (with --drive-backed) from $SEED_SRC ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$ORIGINALS_CACHE"
"$FIXTURE_BIN" seed \
    --catalog "$CATALOG_PATH" \
    --cache "$PREVIEW_CACHE" \
    --seed-dir "$SEED_SRC" \
    --drive-backed

if [ ! -f "$CATALOG_PATH" ]; then
    echo "ERROR: dimroom-fixture did not produce $CATALOG_PATH"
    exit 1
fi

echo "=== Launching app in harness mode (hold-until-released stub downloader) ==="
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_HARNESS_DISABLE_DRIVE=1 \
DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0 \
DIMROOM_HARNESS_STUB_DOWNLOADER="hold-until-released" \
DIMROOM_ORIGINALS_CACHE_BYTES="1048576" \
    "$APP_BIN" --harness \
    --fixture-catalog "$CATALOG_PATH" \
    --preview-cache "$PREVIEW_CACHE" \
    --originals-cache "$ORIGINALS_CACHE" &
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

echo "=== navigate library ==="
NAV_OUT=$("$CLI_BIN" navigate library --socket "$SOCKET")
echo "$NAV_OUT"
if ! echo "$NAV_OUT" | grep -q '"ok"'; then
    echo "ERROR: navigate library did not return ok"
    exit 1
fi

echo "=== list-assets — resolve A (drive-backed.jpg) and B (first seed jpg) ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"

# A is the Drive-only fixture row by filename. B is the first non-drive
# row by filename — the fixture seeds 01/02/03 in lexical order, so 01
# is a stable B.
ASSET_A=$(paste \
    <(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[*].id') \
    <(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[*].originalFilename') \
    | awk -F'\t' '$2 == "drive-backed.jpg" { print $1; exit }')
ASSET_B=$(paste \
    <(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[*].id') \
    <(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[*].originalFilename') \
    | awk -F'\t' '$2 == "01.jpg" { print $1; exit }')

if [ -z "$ASSET_A" ]; then
    echo "ERROR: failed to find Drive-only fixture row in list-assets"
    exit 1
fi
if [ -z "$ASSET_B" ]; then
    echo "ERROR: failed to find local fixture row 01.jpg in list-assets"
    exit 1
fi
echo "  A (drive-only) = $ASSET_A"
echo "  B (local)      = $ASSET_B"

echo "=== select A + navigate develop (kicks off A's held fetch) ==="
"$CLI_BIN" select-asset "$ASSET_A" --socket "$SOCKET" > /dev/null
"$CLI_BIN" navigate develop --socket "$SOCKET" > /dev/null

echo "=== Poll state until A is mid-fetch (developIsDownloadingOriginal == true) ==="
# The hold downloader parks indefinitely, so this just confirms the
# fetch reached the stub. Poll for up to ~2 s at 50 ms intervals.
MID_HIT=""
for i in $(seq 1 40); do
    STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
    DEV_FLAG=$(printf '%s' "$STATE_OUT" \
        | "$REPO_ROOT/bin/harness-json-extract" 'data.developIsDownloadingOriginal' --default 'false')
    if [ "$DEV_FLAG" = "true" ]; then
        MID_HIT="yes"
        echo "  developIsDownloadingOriginal == true after ${i} polls"
        break
    fi
    sleep 0.05
done
if [ -z "$MID_HIT" ]; then
    echo "ERROR: never observed developIsDownloadingOriginal == true for A"
    echo "  Last state: $STATE_OUT"
    exit 1
fi

echo "=== screenshot mid-fetch (A active, overlay up) ==="
mkdir -p "$SCREENSHOT_DIR"
SHOT_PATH="$SCREENSHOT_DIR/asset-switch-pre.png"
SHOT_OUT=$("$CLI_BIN" screenshot "$SHOT_PATH" --socket "$SOCKET")
if ! echo "$SHOT_OUT" | grep -q '"ok"'; then
    echo "ERROR: pre-switch screenshot did not return ok"
    exit 1
fi
if [ ! -f "$SHOT_PATH" ]; then
    echo "ERROR: pre-switch screenshot file not created at $SHOT_PATH"
    exit 1
fi

echo "=== set-edit-parameter B exposure 1.0 (auto-activate triggers re-entry into fetchOriginalIfNeeded) ==="
# This is the exact path that exposed #204 — HarnessController's
# handleSetEditParameter sees currentAssetId != B and calls
# developViewModel.activate(assetId: B), which re-enters
# fetchOriginalIfNeeded. Before #204's fix, A's task remained pinned and
# isDownloadingOriginal stayed true.
SWITCH_OUT=$("$CLI_BIN" set-edit-parameter "$ASSET_B" exposure 1.0 --socket "$SOCKET")
echo "$SWITCH_OUT"
if ! echo "$SWITCH_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-edit-parameter on B did not return ok"
    exit 1
fi

echo "=== Immediate state assertion: overlay cleared, B is current ==="
# No sleep on purpose — #204 was about *immediate* stale state. Any
# tolerance here would mask a regression that re-introduces the bug.
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
DEV_FLAG=$(printf '%s' "$STATE_OUT" \
    | "$REPO_ROOT/bin/harness-json-extract" 'data.developIsDownloadingOriginal' --default 'true')
if [ "$DEV_FLAG" != "false" ]; then
    echo "ERROR: developIsDownloadingOriginal expected 'false', got '$DEV_FLAG'"
    echo "  This is the #204 regression — overlay stuck after asset switch."
    echo "  Full state: $STATE_OUT"
    exit 1
fi
echo "  OK: developIsDownloadingOriginal == false immediately after switch"

DEV_PROGRESS_ABSENT=$(printf '%s' "$STATE_OUT" \
    | "$REPO_ROOT/bin/harness-json-extract" 'data.developDownloadProgress' --absent)
if [ "$DEV_PROGRESS_ABSENT" != "absent" ]; then
    echo "ERROR: developDownloadProgress should be absent/null after switch, was present"
    echo "  Full state: $STATE_OUT"
    exit 1
fi
echo "  OK: developDownloadProgress absent (nil) after switch"

DEV_CURRENT=$(printf '%s' "$STATE_OUT" \
    | "$REPO_ROOT/bin/harness-json-extract" 'data.developCurrentAssetId' --default '')
if [ "$DEV_CURRENT" != "$ASSET_B" ]; then
    echo "ERROR: expected developCurrentAssetId == $ASSET_B (B), got '$DEV_CURRENT'"
    exit 1
fi
echo "  OK: developCurrentAssetId == B"

echo "=== screenshot post-switch (B active, no overlay) ==="
SHOT_PATH="$SCREENSHOT_DIR/asset-switch-post.png"
SHOT_OUT=$("$CLI_BIN" screenshot "$SHOT_PATH" --socket "$SOCKET")
if ! echo "$SHOT_OUT" | grep -q '"ok"'; then
    echo "ERROR: post-switch screenshot did not return ok"
    exit 1
fi

echo "=== release-held-downloads (drain A's now-orphaned fetch) ==="
REL_OUT=$("$CLI_BIN" release-held-downloads --socket "$SOCKET")
echo "$REL_OUT"
if ! echo "$REL_OUT" | grep -q '"ok"'; then
    echo "ERROR: release-held-downloads did not return ok"
    exit 1
fi

echo "=== Verify late tail of A doesn't flip the flag back on for B ==="
# Poll for ~500 ms confirming `developIsDownloadingOriginal` stays
# `false`. A's task should be cancelled, but even if cancellation
# observation is delayed the completion closure gates on
# `currentAssetId == assetId` (A != current B), so it must not write.
for i in $(seq 1 10); do
    STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
    DEV_FLAG=$(printf '%s' "$STATE_OUT" \
        | "$REPO_ROOT/bin/harness-json-extract" 'data.developIsDownloadingOriginal' --default 'true')
    if [ "$DEV_FLAG" != "false" ]; then
        echo "ERROR: developIsDownloadingOriginal flipped to '$DEV_FLAG' after release"
        echo "  Iteration $i. Full state: $STATE_OUT"
        exit 1
    fi
    sleep 0.05
done
echo "  OK: developIsDownloadingOriginal stayed false across post-release polls"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness develop asset-switch mid-fetch flow PASSED ==="
