#!/usr/bin/env bash
# harness-undo-flow.sh — Layer C flow for Cmd+Z undo / Cmd+Shift+Z redo.
#
# Seeds a throwaway catalog, launches the app in harness mode, drives a
# rating change, undoes it, redoes it, then drives a rotation and undoes
# that too. Asserts the catalog-backed state after each operation via
# `list-assets`, which now includes a `rotation` field.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/undo}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-undo"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-undo-$$.sock"
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

sleep 1

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

get_field() {
    local id="$1"
    local key="$2"
    "$CLI_BIN" list-assets --socket "$SOCKET" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
for a in doc['data']:
    if a['id'] == '$id':
        print(a['$key'])
        break
"
}

INITIAL_RATING=$(get_field "$ASSET_ID" rating)
INITIAL_ROTATION=$(get_field "$ASSET_ID" rotation)
echo "  Initial rating=$INITIAL_RATING rotation=$INITIAL_ROTATION"

# ------------------------------------------------------------------
# 1. Set rating → assert → undo → assert restored → redo → assert
# ------------------------------------------------------------------

echo "=== set-rating $ASSET_ID 4 ==="
"$CLI_BIN" set-rating "$ASSET_ID" 4 --socket "$SOCKET" >/dev/null

POST_RATE=$(get_field "$ASSET_ID" rating)
if [ "$POST_RATE" != "4" ]; then
    echo "ERROR: expected rating 4 after set-rating, got '$POST_RATE'"
    exit 1
fi
echo "  OK: rating == 4"

mkdir -p "$SCREENSHOT_DIR"
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/undo-01-after-rate.png" --socket "$SOCKET" >/dev/null

echo "=== undo ==="
UNDO_OUT=$("$CLI_BIN" undo --socket "$SOCKET")
echo "$UNDO_OUT"
if ! echo "$UNDO_OUT" | grep -q '"ok"'; then
    echo "ERROR: undo did not return ok"
    exit 1
fi

POST_UNDO=$(get_field "$ASSET_ID" rating)
if [ "$POST_UNDO" != "$INITIAL_RATING" ]; then
    echo "ERROR: expected rating $INITIAL_RATING after undo, got '$POST_UNDO'"
    exit 1
fi
echo "  OK: rating restored to $INITIAL_RATING"

"$CLI_BIN" screenshot "$SCREENSHOT_DIR/undo-02-after-undo-rating.png" --socket "$SOCKET" >/dev/null

echo "=== redo ==="
REDO_OUT=$("$CLI_BIN" redo --socket "$SOCKET")
echo "$REDO_OUT"
if ! echo "$REDO_OUT" | grep -q '"ok"'; then
    echo "ERROR: redo did not return ok"
    exit 1
fi

POST_REDO=$(get_field "$ASSET_ID" rating)
if [ "$POST_REDO" != "4" ]; then
    echo "ERROR: expected rating 4 after redo, got '$POST_REDO'"
    exit 1
fi
echo "  OK: redo re-applied rating 4"

# ------------------------------------------------------------------
# 2. Rotate → assert new rotation → undo → assert restored
# ------------------------------------------------------------------

echo "=== rotate $ASSET_ID ==="
"$CLI_BIN" rotate "$ASSET_ID" --socket "$SOCKET" >/dev/null

EXPECTED_ROT=$(( (INITIAL_ROTATION + 90) % 360 ))
POST_ROT=$(get_field "$ASSET_ID" rotation)
if [ "$POST_ROT" != "$EXPECTED_ROT" ]; then
    echo "ERROR: expected rotation $EXPECTED_ROT after rotate, got '$POST_ROT'"
    exit 1
fi
echo "  OK: rotation == $POST_ROT"

sleep 2

"$CLI_BIN" screenshot "$SCREENSHOT_DIR/undo-03-after-rotate.png" --socket "$SOCKET" >/dev/null

echo "=== undo rotation ==="
"$CLI_BIN" undo --socket "$SOCKET" >/dev/null

sleep 2

POST_UNDO_ROT=$(get_field "$ASSET_ID" rotation)
if [ "$POST_UNDO_ROT" != "$INITIAL_ROTATION" ]; then
    echo "ERROR: expected rotation $INITIAL_ROTATION after undo, got '$POST_UNDO_ROT'"
    exit 1
fi
echo "  OK: rotation restored to $INITIAL_ROTATION"

"$CLI_BIN" screenshot "$SCREENSHOT_DIR/undo-04-after-undo-rotate.png" --socket "$SOCKET" >/dev/null

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness undo flow PASSED ==="
