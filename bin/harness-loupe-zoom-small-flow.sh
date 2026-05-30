#!/usr/bin/env bash
# harness-loupe-zoom-small-flow.sh — Layer C flow for the small-image
# branch of toggleFitTo100 (Z-key zoom) added in PR #173 / issue #147.
#
# The existing bin/harness-zoom-flow.sh uses 2048x2048 fixtures where
# the loupe container is smaller than the image (fit <= 1.0), so it
# exercises only the "fit -> 1.0" branch of toggleFitTo100.
#
# This flow seeds a 300x300 image so the container is larger than the
# image (fit > 1.0). Pre-#147, toggleFitTo100 clamped scale back to fit
# and isZoomed stayed false (silent no-op). Post-#147, scale jumps to
# min(maxZoom, max(1.0, fit*2)) which is well above fit, so
# syncIsZoomed flips to true. This flow fails if that regression
# returns.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set
# by the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/loupe-zoom-small}"
SEED_SRC="$REPO_ROOT/fixtures/loupe-small"
WORK_DIR="$REPO_ROOT/.artifacts/harness-loupe-zoom-small"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
# Scope the originals staging dir + LRU originals cache under $WORK_DIR so
# any originals fetch writes its downloads + index.json here, never into the
# user's real ~/Library/Application Support/Dimroom/originals (issue #331).
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-loupe-zoom-small-$$.sock"
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

echo "=== list-assets — pick first asset id ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"
ASSET_ID=$(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[0].id')
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

mkdir -p "$SCREENSHOT_DIR"

echo "=== state — assert isZoomed == false before any zoom ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
IS_ZOOMED=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.isZoomed')
if [ "$IS_ZOOMED" != "false" ]; then
    echo "ERROR: expected isZoomed == false before zoom, got '$IS_ZOOMED'"
    exit 1
fi
echo "  OK: isZoomed == false (initial, small image fits with scale==fit)"

echo "=== zoomToggle — small-image branch: scale jumps above fit ==="
ZOOM_OUT=$("$CLI_BIN" zoom-toggle --socket "$SOCKET")
echo "$ZOOM_OUT"
if ! echo "$ZOOM_OUT" | grep -q '"ok"'; then
    echo "ERROR: zoomToggle did not return ok"
    exit 1
fi

# Give SwiftUI time to execute the zoom command via .onChange
sleep 1

echo "=== state — assert isZoomed == true after zoomToggle (regression guard for #147) ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
IS_ZOOMED=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.isZoomed')
if [ "$IS_ZOOMED" != "true" ]; then
    echo "ERROR: expected isZoomed == true after zoomToggle on small image; got '$IS_ZOOMED'."
    echo "       Pre-#147 behaviour: toggleFitTo100 clamped back to fit on small images (silent no-op)."
    exit 1
fi
echo "  OK: isZoomed == true (small-image zoom-in branch active)"

take_screenshot "zoom-toggled"

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
IS_ZOOMED=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.isZoomed')
if [ "$IS_ZOOMED" != "false" ]; then
    echo "ERROR: expected isZoomed == false after zoomReset, got '$IS_ZOOMED'"
    exit 1
fi
echo "  OK: isZoomed == false (after zoomReset)"

take_screenshot "zoom-reset"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness loupe-zoom-small flow PASSED ==="
