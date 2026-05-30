#!/usr/bin/env bash
# harness-library-flow.sh — Layer C flow for the library grid.
#
# Seeds a throwaway catalog from fixtures/library-seed/ with the
# dimroom-fixture binary, launches the app in harness mode, navigates to
# the library route, takes a screenshot, asserts assetCount > 0, then
# selects an asset, rotates it, and screenshots the grid again to verify
# the layout holds after rotation.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set by
# the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/library}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-library"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
# Scope the originals staging dir + LRU originals cache under $WORK_DIR so
# any originals fetch writes its downloads + index.json here, never into the
# user's real ~/Library/Application Support/Dimroom/originals (issue #331).
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-library-$$.sock"
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

echo "=== Seeding catalog from $SEED_SRC ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$ORIGINALS_CACHE"
"$FIXTURE_BIN" seed \
    --catalog "$CATALOG_PATH" \
    --cache "$PREVIEW_CACHE" \
    --seed-dir "$SEED_SRC"

if [ ! -f "$CATALOG_PATH" ]; then
    echo "ERROR: dimroom-fixture did not produce $CATALOG_PATH"
    exit 1
fi

echo "=== Launching app in harness mode ==="
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_HARNESS_DISABLE_DRIVE=1 \
DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0 \
DIMROOM_ORIGINALS_DIR="$ORIGINALS_CACHE" \
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

# Small paint delay — SwiftUI needs a tick after the route change
# before the grid is actually drawn.
sleep 1

echo "=== screenshot ==="
mkdir -p "$SCREENSHOT_DIR"
SHOT_PATH="$SCREENSHOT_DIR/library-populated.png"
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
echo "Screenshot verified: $FILE_TYPE"

echo "=== state — assert assetCount > 0 ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
ASSET_COUNT=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.assetCount')
if [ -z "$ASSET_COUNT" ] || [ "$ASSET_COUNT" -le 0 ]; then
    echo "ERROR: expected assetCount > 0, got '$ASSET_COUNT'"
    exit 1
fi
echo "  OK: assetCount == $ASSET_COUNT"

echo "=== list-assets — grab first UUID ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"
FIRST_UUID=$(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[0].id')
if [ -z "$FIRST_UUID" ]; then
    echo "ERROR: could not extract first asset UUID"
    exit 1
fi
echo "  First asset UUID: $FIRST_UUID"

echo "=== select-asset $FIRST_UUID ==="
SEL_OUT=$("$CLI_BIN" select-asset "$FIRST_UUID" --socket "$SOCKET")
echo "$SEL_OUT"
if ! echo "$SEL_OUT" | grep -q '"ok"'; then
    echo "ERROR: select-asset did not return ok"
    exit 1
fi

echo "=== rotate $FIRST_UUID ==="
ROT_OUT=$("$CLI_BIN" rotate "$FIRST_UUID" --socket "$SOCKET")
echo "$ROT_OUT"
if ! echo "$ROT_OUT" | grep -q '"ok"'; then
    echo "ERROR: rotate did not return ok"
    exit 1
fi

# Longer paint delay — rotate triggers preview regeneration + SwiftUI repaint
sleep 2

echo "=== screenshot after rotate ==="
ROT_SHOT_PATH="$SCREENSHOT_DIR/library-after-rotate.png"
ROT_SHOT_OUT=$("$CLI_BIN" screenshot "$ROT_SHOT_PATH" --socket "$SOCKET")
echo "$ROT_SHOT_OUT"
if ! echo "$ROT_SHOT_OUT" | grep -q '"ok"'; then
    echo "ERROR: screenshot (after rotate) did not return ok"
    exit 1
fi
if [ ! -f "$ROT_SHOT_PATH" ]; then
    echo "ERROR: screenshot file not created at $ROT_SHOT_PATH"
    exit 1
fi
ROT_FILE_TYPE=$(file -b "$ROT_SHOT_PATH")
if ! echo "$ROT_FILE_TYPE" | grep -qi "png"; then
    echo "ERROR: screenshot (after rotate) is not a valid PNG: $ROT_FILE_TYPE"
    exit 1
fi
echo "Screenshot (after rotate) verified: $ROT_FILE_TYPE"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness library flow PASSED ==="
