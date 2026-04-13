#!/usr/bin/env bash
# harness-zoom-flow.sh — Layer C flow for zoomToggle / zoomReset.
#
# Seeds a 3-asset catalog, selects an asset, navigates to loupe, takes a
# baseline screenshot, sends zoomToggle and screenshots, sends zoomToggle
# again and screenshots (toggle back), sends zoomReset and screenshots.
# Asserts all commands return ok and all screenshots are valid PNGs.
#
# Note: AppState does not include a zoom-level field, so this flow can
# only assert command success + valid PNG screenshots — it cannot
# programmatically confirm the zoom level changed.
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

# Helper: take a screenshot, assert it's a valid PNG
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
    local file_type
    file_type=$(file -b "$shot_path")
    if ! echo "$file_type" | grep -qi "png"; then
        echo "ERROR: screenshot is not a valid PNG: $file_type"
        exit 1
    fi
    echo "  Screenshot verified: $file_type"
}

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

# SwiftUI needs a tick after the route change before the loupe view is drawn.
sleep 1

mkdir -p "$SCREENSHOT_DIR"

# Baseline screenshot
take_screenshot "zoom-baseline"

# --- zoomToggle: zoom in ---
echo "=== zoomToggle (zoom in) ==="
ZT_OUT=$("$CLI_BIN" zoom-toggle --socket "$SOCKET")
echo "$ZT_OUT"
if ! echo "$ZT_OUT" | grep -q '"ok"'; then
    echo "ERROR: zoom-toggle did not return ok"
    exit 1
fi
sleep 1
take_screenshot "zoom-toggled-in"

# --- zoomToggle again: zoom back out ---
echo "=== zoomToggle (zoom back out) ==="
ZT_OUT=$("$CLI_BIN" zoom-toggle --socket "$SOCKET")
echo "$ZT_OUT"
if ! echo "$ZT_OUT" | grep -q '"ok"'; then
    echo "ERROR: zoom-toggle did not return ok"
    exit 1
fi
sleep 1
take_screenshot "zoom-toggled-out"

# --- zoomReset ---
echo "=== zoomReset ==="
ZR_OUT=$("$CLI_BIN" zoom-reset --socket "$SOCKET")
echo "$ZR_OUT"
if ! echo "$ZR_OUT" | grep -q '"ok"'; then
    echo "ERROR: zoom-reset did not return ok"
    exit 1
fi
sleep 1
take_screenshot "zoom-reset"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness zoom flow PASSED ==="
