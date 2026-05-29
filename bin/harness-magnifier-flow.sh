#!/usr/bin/env bash
# harness-magnifier-flow.sh — Layer C flow for the Develop pixel magnifier (#324).
#
# Seeds a throwaway catalog, launches the app in harness mode, picks an
# asset, enters Develop, then drives `set-magnifier` to: show the magnifier
# at a known sample point + zoom, move the sample point, switch zoom 2→1,
# and hide it — asserting state.data.magnifier reflects each change and
# taking screenshots along the way.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set by
# the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/magnifier}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-magnifier"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-magnifier-$$.sock"
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

# Extract a field from a `state` response's data.magnifier block.
# Usage: magnifier_field <json> <field>
magnifier_field() {
    printf '%s' "$1" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(doc['data']['magnifier']['$2'])
"
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
DIMROOM_HARNESS_DISABLE_DRIVE=1 \
DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0 \
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

mkdir -p "$SCREENSHOT_DIR"

echo "=== navigate library ==="
"$CLI_BIN" navigate library --socket "$SOCKET" >/dev/null

echo "=== list-assets — pick first asset id ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
ASSET_ID=$(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[0].id')
if [ -z "$ASSET_ID" ]; then
    echo "ERROR: failed to extract asset id from list-assets"
    exit 1
fi
echo "  Picked asset id: $ASSET_ID"

echo "=== select-asset + navigate develop ==="
"$CLI_BIN" select-asset "$ASSET_ID" --socket "$SOCKET" >/dev/null
"$CLI_BIN" navigate develop --socket "$SOCKET" >/dev/null
sleep 1

echo "=== set-magnifier --visible true --x 0.5 --y 0.5 --zoom 2 ==="
"$CLI_BIN" set-magnifier --visible true --x 0.5 --y 0.5 --zoom 2 --socket "$SOCKET" >/dev/null
sleep 1

STATE=$("$CLI_BIN" state --socket "$SOCKET")
VISIBLE=$(magnifier_field "$STATE" visible)
ZOOM=$(magnifier_field "$STATE" zoom)
if [ "$VISIBLE" != "True" ]; then
    echo "ERROR: expected magnifier.visible == True, got '$VISIBLE'"
    exit 1
fi
if [ "$ZOOM" != "2" ]; then
    echo "ERROR: expected magnifier.zoom == 2, got '$ZOOM'"
    exit 1
fi
echo "  OK: visible=$VISIBLE zoom=$ZOOM"

echo "=== screenshot: magnifier visible at centre, 2:1 ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/magnifier-centre-2to1.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/magnifier-centre-2to1.png" ]; then
    echo "ERROR: centre screenshot not created"
    exit 1
fi

echo "=== set-magnifier — move sample point to (0.25, 0.25) ==="
"$CLI_BIN" set-magnifier --visible true --x 0.25 --y 0.25 --zoom 2 --socket "$SOCKET" >/dev/null
sleep 1

STATE=$("$CLI_BIN" state --socket "$SOCKET")
SAMPLE_X=$(magnifier_field "$STATE" samplePointX)
MATCH=$(/usr/bin/python3 -c "print('ok' if abs(float('$SAMPLE_X') - 0.25) < 1e-6 else 'no')")
if [ "$MATCH" != "ok" ]; then
    echo "ERROR: expected magnifier.samplePointX ~0.25, got '$SAMPLE_X'"
    exit 1
fi
echo "  OK: samplePointX=$SAMPLE_X"
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/magnifier-moved.png" --socket "$SOCKET" >/dev/null

echo "=== set-magnifier --zoom 1 (sample point unchanged) ==="
"$CLI_BIN" set-magnifier --visible true --zoom 1 --socket "$SOCKET" >/dev/null
sleep 1

STATE=$("$CLI_BIN" state --socket "$SOCKET")
ZOOM=$(magnifier_field "$STATE" zoom)
SAMPLE_X=$(magnifier_field "$STATE" samplePointX)
if [ "$ZOOM" != "1" ]; then
    echo "ERROR: expected magnifier.zoom == 1, got '$ZOOM'"
    exit 1
fi
MATCH=$(/usr/bin/python3 -c "print('ok' if abs(float('$SAMPLE_X') - 0.25) < 1e-6 else 'no')")
if [ "$MATCH" != "ok" ]; then
    echo "ERROR: zoom switch should not move the sample point; samplePointX='$SAMPLE_X'"
    exit 1
fi
echo "  OK: zoom=$ZOOM samplePointX=$SAMPLE_X (unchanged)"
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/magnifier-1to1.png" --socket "$SOCKET" >/dev/null

echo "=== set-magnifier --visible false ==="
"$CLI_BIN" set-magnifier --visible false --socket "$SOCKET" >/dev/null
sleep 1

STATE=$("$CLI_BIN" state --socket "$SOCKET")
VISIBLE=$(magnifier_field "$STATE" visible)
if [ "$VISIBLE" != "False" ]; then
    echo "ERROR: expected magnifier.visible == False after hide, got '$VISIBLE'"
    exit 1
fi
echo "  OK: visible=$VISIBLE"
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/magnifier-hidden.png" --socket "$SOCKET" >/dev/null

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness magnifier flow PASSED ==="
