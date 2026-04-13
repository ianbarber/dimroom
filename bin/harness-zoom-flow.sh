#!/usr/bin/env bash
# harness-zoom-flow.sh — Layer C flow for zoom toggle/reset with isZoomed assertions.
#
# Seeds a throwaway catalog, launches the app in harness mode, selects an
# asset, navigates to loupe, then exercises zoomToggle and zoomReset
# commands while asserting isZoomed state transitions in the AppState
# response.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set
# by the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/zoom}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-zoom"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-zoom-$$.sock"
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
mkdir -p "$WORK_DIR"
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

echo "=== navigate library ==="
NAV_OUT=$("$CLI_BIN" navigate library --socket "$SOCKET")
echo "$NAV_OUT"
if ! echo "$NAV_OUT" | grep -q '"ok"'; then
    echo "ERROR: navigate library did not return ok"
    exit 1
fi

echo "=== list-assets — pick first asset id ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"
ASSET_ID=$(printf '%s' "$LIST_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(doc['data'][0]['id'])
")
if [ -z "$ASSET_ID" ]; then
    echo "ERROR: failed to extract asset id from list-assets response"
    exit 1
fi
echo "  Picked asset id: $ASSET_ID"

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

# Let SwiftUI settle after route change
sleep 1

echo "=== state — assert isZoomed == false before any zoom ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
IS_ZOOMED=$(printf '%s' "$STATE_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(str(doc['data']['isZoomed']).lower())
")
if [ "$IS_ZOOMED" != "false" ]; then
    echo "ERROR: expected isZoomed == false before zoom, got '$IS_ZOOMED'"
    exit 1
fi
echo "  OK: isZoomed == false (initial)"

echo "=== zoomToggle — zoom in ==="
ZOOM_OUT=$("$CLI_BIN" zoom-toggle --socket "$SOCKET")
echo "$ZOOM_OUT"
if ! echo "$ZOOM_OUT" | grep -q '"ok"'; then
    echo "ERROR: zoomToggle did not return ok"
    exit 1
fi

# Give SwiftUI time to execute the zoom command via .onChange
sleep 1

echo "=== state — assert isZoomed == true after zoomToggle ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
IS_ZOOMED=$(printf '%s' "$STATE_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(str(doc['data']['isZoomed']).lower())
")
if [ "$IS_ZOOMED" != "true" ]; then
    echo "ERROR: expected isZoomed == true after zoomToggle, got '$IS_ZOOMED'"
    exit 1
fi
echo "  OK: isZoomed == true (after zoomToggle)"

echo "=== screenshot (zoomed) ==="
mkdir -p "$SCREENSHOT_DIR"
SHOT_PATH="$SCREENSHOT_DIR/zoom-toggled.png"
SHOT_OUT=$("$CLI_BIN" screenshot "$SHOT_PATH" --socket "$SOCKET")
echo "$SHOT_OUT"
if ! echo "$SHOT_OUT" | grep -q '"ok"'; then
    echo "ERROR: screenshot command did not return ok"
    exit 1
fi

echo "=== zoomReset ==="
RESET_OUT=$("$CLI_BIN" zoom-reset --socket "$SOCKET")
echo "$RESET_OUT"
if ! echo "$RESET_OUT" | grep -q '"ok"'; then
    echo "ERROR: zoomReset did not return ok"
    exit 1
fi

sleep 1

echo "=== state — assert isZoomed == false after zoomReset ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
IS_ZOOMED=$(printf '%s' "$STATE_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(str(doc['data']['isZoomed']).lower())
")
if [ "$IS_ZOOMED" != "false" ]; then
    echo "ERROR: expected isZoomed == false after zoomReset, got '$IS_ZOOMED'"
    exit 1
fi
echo "  OK: isZoomed == false (after zoomReset)"

echo "=== screenshot (reset) ==="
SHOT_PATH="$SCREENSHOT_DIR/zoom-reset.png"
SHOT_OUT=$("$CLI_BIN" screenshot "$SHOT_PATH" --socket "$SOCKET")
echo "$SHOT_OUT"
if ! echo "$SHOT_OUT" | grep -q '"ok"'; then
    echo "ERROR: screenshot command did not return ok"
    exit 1
fi

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness zoom flow PASSED ==="
