#!/usr/bin/env bash
# harness-develop-undo-flow.sh — Layer C flow for Cmd+Z undo in Develop.
#
# Regression guard for #131. Pushes an exposure via set-edit-parameter
# inside Develop, waits past the 500ms auto-save debounce, fires undo,
# asserts the catalog + live DevelopViewModel edit state both rolled
# back to identity, then redoes and asserts the slider value returns.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/develop-undo}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-develop-undo"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-develop-undo-$$.sock"
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

get_exposure() {
    local id="$1"
    "$CLI_BIN" get-edit "$id" --socket "$SOCKET" \
        | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
data = doc.get('data')
if data is None:
    print('0.0')
else:
    print(float(data.get('exposure', 0.0)))
"
}

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

echo "=== select-asset $ASSET_ID ==="
"$CLI_BIN" select-asset "$ASSET_ID" --socket "$SOCKET" >/dev/null

echo "=== navigate develop ==="
"$CLI_BIN" navigate develop --socket "$SOCKET" >/dev/null
sleep 1

"$CLI_BIN" screenshot "$SCREENSHOT_DIR/01-develop-identity.png" --socket "$SOCKET" >/dev/null

echo "=== set-edit-parameter $ASSET_ID exposure 2.0 ==="
SET_OUT=$("$CLI_BIN" set-edit-parameter "$ASSET_ID" exposure 2.0 --socket "$SOCKET")
if ! echo "$SET_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-edit-parameter did not return ok"
    echo "$SET_OUT"
    exit 1
fi
# Wait out the 500ms save debounce so scheduleSave pushes `.editSave`.
sleep 1

POST_SET_EXPOSURE=$(get_exposure "$ASSET_ID")
if [ "$POST_SET_EXPOSURE" != "2.0" ]; then
    echo "ERROR: expected exposure 2.0 after set, got '$POST_SET_EXPOSURE'"
    exit 1
fi
echo "  OK: exposure set to 2.0"
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/02-develop-exposure-plus2.png" --socket "$SOCKET" >/dev/null

echo "=== undo ==="
UNDO_OUT=$("$CLI_BIN" undo --socket "$SOCKET")
if ! echo "$UNDO_OUT" | grep -q '"ok"'; then
    echo "ERROR: undo did not return ok"
    echo "$UNDO_OUT"
    exit 1
fi
sleep 1

POST_UNDO_EXPOSURE=$(get_exposure "$ASSET_ID")
if [ "$POST_UNDO_EXPOSURE" != "0.0" ]; then
    echo "ERROR: expected exposure 0.0 after undo, got '$POST_UNDO_EXPOSURE'"
    exit 1
fi
echo "  OK: undo rolled exposure back to 0.0"
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/03-develop-after-undo.png" --socket "$SOCKET" >/dev/null

echo "=== redo ==="
REDO_OUT=$("$CLI_BIN" redo --socket "$SOCKET")
if ! echo "$REDO_OUT" | grep -q '"ok"'; then
    echo "ERROR: redo did not return ok"
    echo "$REDO_OUT"
    exit 1
fi
sleep 1

POST_REDO_EXPOSURE=$(get_exposure "$ASSET_ID")
if [ "$POST_REDO_EXPOSURE" != "2.0" ]; then
    echo "ERROR: expected exposure 2.0 after redo, got '$POST_REDO_EXPOSURE'"
    exit 1
fi
echo "  OK: redo re-applied exposure 2.0"
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/04-develop-after-redo.png" --socket "$SOCKET" >/dev/null

# ------------------------------------------------------------------
# Hydration check: leave Develop, come back, Cmd+Z must still work
# against the persisted version history.
# ------------------------------------------------------------------

echo "=== navigate library (leave develop) ==="
"$CLI_BIN" navigate library --socket "$SOCKET" >/dev/null
sleep 1

echo "=== select-asset $ASSET_ID ==="
"$CLI_BIN" select-asset "$ASSET_ID" --socket "$SOCKET" >/dev/null

echo "=== navigate develop (re-entry, undo stack should hydrate) ==="
"$CLI_BIN" navigate develop --socket "$SOCKET" >/dev/null
sleep 1

echo "=== undo after re-entry ==="
UNDO2_OUT=$("$CLI_BIN" undo --socket "$SOCKET")
if ! echo "$UNDO2_OUT" | grep -q '"ok"'; then
    echo "ERROR: undo after re-entry did not return ok"
    echo "$UNDO2_OUT"
    exit 1
fi
sleep 1

POST_REHYDRATE_EXPOSURE=$(get_exposure "$ASSET_ID")
# Hydration walks back through on-disk history. The prior step left the
# catalog at exposure=2.0 (redo of the original set), so undoing after
# re-entry should roll exposure back below 2.0.
if [ "$POST_REHYDRATE_EXPOSURE" = "2.0" ]; then
    echo "ERROR: undo after re-entry did not change exposure — hydration not active"
    exit 1
fi
echo "  OK: undo after re-entry rolled exposure to $POST_REHYDRATE_EXPOSURE (hydration working)"
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/05-develop-after-rehydrate-undo.png" --socket "$SOCKET" >/dev/null

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness develop-undo flow PASSED ==="
