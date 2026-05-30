#!/usr/bin/env bash
# harness-download-flow.sh — Layer C flow for the Drive-backed download
# overlay (#149). Seeds a catalog containing one Drive-only fixture
# asset, launches the app with the slow-chunks stub downloader injected,
# navigates to loupe on that asset, polls `state` until the download is
# in flight, screenshots the determinate `DownloadIndicatorView`
# overlay, and waits for the download to finish.
#
# Not wired into bin/harness-smoke.sh / CI yet — see #149's out-of-scope
# note. Run locally with:
#   bin/harness-download-flow.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/download}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-download"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-download-$$.sock"
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

echo "=== Launching app in harness mode (slow-chunks stub downloader) ==="
# HARNESS_WORK_DIR scopes both DIMROOM_ORIGINALS_DIR and --originals-cache to
# $WORK_DIR/originals (== $ORIGINALS_CACHE); the stub downloader + cache budget
# ride along in HARNESS_ENV.
FIXTURE_CATALOG="$CATALOG_PATH"
HARNESS_WORK_DIR="$WORK_DIR"
HARNESS_ENV=(
    DIMROOM_HARNESS_DISABLE_DRIVE=1
    DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0
    DIMROOM_HARNESS_STUB_DOWNLOADER=slow-chunks
    DIMROOM_ORIGINALS_CACHE_BYTES=1048576
)
harness_launch_app

echo "=== navigate library ==="
NAV_OUT=$("$CLI_BIN" navigate library --socket "$SOCKET")
echo "$NAV_OUT"
if ! echo "$NAV_OUT" | grep -q '"ok"'; then
    echo "ERROR: navigate library did not return ok"
    exit 1
fi

echo "=== list-assets — find the Drive-only asset ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"

# The seeder names the Drive-backed fixture row "drive-backed.jpg".
# Match on filename to grab its id without depending on grid sort order.
ASSET_ID=$(paste \
    <(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[*].id') \
    <(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[*].originalFilename') \
    | awk -F'\t' '$2 == "drive-backed.jpg" { print $1; exit }')
if [ -z "$ASSET_ID" ]; then
    echo "ERROR: failed to find Drive-only fixture row in list-assets"
    exit 1
fi
echo "  Drive-only asset id: $ASSET_ID"

echo "=== select-asset $ASSET_ID ==="
SEL_OUT=$("$CLI_BIN" select-asset "$ASSET_ID" --socket "$SOCKET")
echo "$SEL_OUT"
if ! echo "$SEL_OUT" | grep -q '"ok"'; then
    echo "ERROR: select-asset did not return ok"
    exit 1
fi

echo "=== navigate loupe ==="
LOUPE_OUT=$("$CLI_BIN" navigate loupe --socket "$SOCKET")
echo "$LOUPE_OUT"
if ! echo "$LOUPE_OUT" | grep -q '"ok"'; then
    echo "ERROR: navigate loupe did not return ok"
    exit 1
fi

# The Loupe view only requests the original when the user zooms in —
# `fit` mode renders the preview. zoom-toggle flips to 100% and triggers
# OriginalsCoordinator.fetchOriginal, which is what pipes through the
# slow-chunks stub.
echo "=== zoom-toggle (kicks off the slow download) ==="
ZOOM_OUT=$("$CLI_BIN" zoom-toggle --socket "$SOCKET")
echo "$ZOOM_OUT"
if ! echo "$ZOOM_OUT" | grep -q '"ok"'; then
    echo "ERROR: zoom-toggle did not return ok"
    exit 1
fi

echo "=== Poll state until download is in-flight (mid-progress) ==="
# Stub paces ~10 chunks × 150 ms ≈ 1.5 s. Poll up to 5 s at 50 ms
# intervals — well within the wall clock window even on a loaded runner.
MID_HIT=""
MID_PROGRESS=""
for i in $(seq 1 100); do
    STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
    DL_LIST=$(printf '%s' "$STATE_OUT" \
        | "$REPO_ROOT/bin/harness-json-extract" 'data.downloadingAssetIds[*]' 2>/dev/null \
        || true)
    if printf '%s\n' "$DL_LIST" | grep -qx "$ASSET_ID"; then
        PROGRESS=$(printf '%s' "$STATE_OUT" \
            | "$REPO_ROOT/bin/harness-json-extract" \
                "data.downloadProgressByAssetId.$ASSET_ID" \
                --float --default '0')
        # bash arithmetic doesn't do floats — use awk for the bound check.
        IS_MID=$(awk -v p="$PROGRESS" 'BEGIN { print (p > 0 && p < 1) ? "yes" : "no" }')
        if [ "$IS_MID" = "yes" ]; then
            MID_HIT="yes"
            MID_PROGRESS="$PROGRESS"
            echo "  Mid-progress observed after ${i} polls: progress=$PROGRESS"
            break
        fi
    fi
    sleep 0.05
done
if [ -z "$MID_HIT" ]; then
    echo "ERROR: never observed downloadingAssetIds containing $ASSET_ID with 0 < progress < 1"
    echo "  Last state: $STATE_OUT"
    exit 1
fi

echo "=== screenshot mid-download ==="
mkdir -p "$SCREENSHOT_DIR"
SHOT_PATH="$SCREENSHOT_DIR/download-mid.png"
SHOT_OUT=$("$CLI_BIN" screenshot "$SHOT_PATH" --socket "$SOCKET")
echo "$SHOT_OUT"
if ! echo "$SHOT_OUT" | grep -q '"ok"'; then
    echo "ERROR: screenshot command did not return ok"
    exit 1
fi
if [ ! -f "$SHOT_PATH" ]; then
    echo "ERROR: screenshot file not created at $SHOT_PATH"
    exit 1
fi
FILE_TYPE=$(file -b "$SHOT_PATH")
if ! echo "$FILE_TYPE" | grep -qi "png"; then
    echo "ERROR: screenshot is not a valid PNG: $FILE_TYPE"
    exit 1
fi
echo "Screenshot verified: $FILE_TYPE (captured at progress=$MID_PROGRESS)"

echo "=== Wait for download to complete ==="
DONE_HIT=""
for i in $(seq 1 200); do
    STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
    DL_LIST=$(printf '%s' "$STATE_OUT" \
        | "$REPO_ROOT/bin/harness-json-extract" 'data.downloadingAssetIds[*]' 2>/dev/null \
        || true)
    if ! printf '%s\n' "$DL_LIST" | grep -qx "$ASSET_ID"; then
        DONE_HIT="yes"
        echo "  Download complete after ${i} polls"
        break
    fi
    sleep 0.05
done
if [ -z "$DONE_HIT" ]; then
    echo "ERROR: download never completed; downloadingAssetIds still contains $ASSET_ID"
    exit 1
fi

echo "=== Final state assertions ==="
STATE_SELECTED=$(printf '%s' "$STATE_OUT" \
    | "$REPO_ROOT/bin/harness-json-extract" 'data.selectedAssetId' --default '')
if [ "$STATE_SELECTED" != "$ASSET_ID" ]; then
    echo "ERROR: expected selectedAssetId == $ASSET_ID, got '$STATE_SELECTED'"
    exit 1
fi
echo "  OK: selectedAssetId == $ASSET_ID"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness download flow PASSED ==="
