#!/usr/bin/env bash
# harness-develop-flow.sh — Layer C flow for the develop view.
#
# Seeds a throwaway catalog, launches the app in harness mode, picks an
# asset, navigates to develop, pushes exposure to +2 via set-edit-parameter,
# verifies get-edit reflects the new value, and takes screenshots at each
# interesting state.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set
# by the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/develop}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-develop"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
# Scope the originals staging dir + LRU originals cache under $WORK_DIR so
# any originals fetch writes its downloads + index.json here, never into the
# user's real ~/Library/Application Support/Dimroom/originals (issue #331).
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-develop-$$.sock"
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
FIXTURE_CATALOG="$CATALOG_PATH"
HARNESS_WORK_DIR="$WORK_DIR"
HARNESS_ENV=(DIMROOM_HARNESS_DISABLE_DRIVE=1 DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0)
harness_launch_app

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

echo "=== select-asset $ASSET_ID ==="
"$CLI_BIN" select-asset "$ASSET_ID" --socket "$SOCKET" >/dev/null

echo "=== navigate develop ==="
"$CLI_BIN" navigate develop --socket "$SOCKET" >/dev/null
# Paint + initial-render delay
sleep 1

echo "=== screenshot: develop at identity ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-identity.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/develop-identity.png" ]; then
    echo "ERROR: identity screenshot not created"
    exit 1
fi

echo "=== set-edit-parameter $ASSET_ID exposure 2.0 ==="
SET_OUT=$("$CLI_BIN" set-edit-parameter "$ASSET_ID" exposure 2.0 --socket "$SOCKET")
echo "$SET_OUT"
if ! echo "$SET_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-edit-parameter did not return ok"
    exit 1
fi
# Wait for debounced render + auto-save (render ~50ms, save ~500ms).
sleep 1

echo "=== get-edit $ASSET_ID — assert exposure == 2.0 ==="
GET_OUT=$("$CLI_BIN" get-edit "$ASSET_ID" --socket "$SOCKET")
echo "$GET_OUT"
# TODO(#122): migrate once harness-json-extract supports --float/--epsilon.
EXPOSURE=$(printf '%s' "$GET_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
# JSON-encoded Doubles lose trailing .0, so normalise to float.
print(float(doc['data']['exposure']))
")
if [ "$EXPOSURE" != "2.0" ]; then
    echo "ERROR: expected exposure == 2.0, got '$EXPOSURE'"
    exit 1
fi
echo "  OK: exposure == $EXPOSURE"

echo "=== screenshot: develop with exposure +2 ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-exposure-plus2.png" --socket "$SOCKET" >/dev/null

echo "=== reset-edit-parameter $ASSET_ID exposure ==="
RESET_OUT=$("$CLI_BIN" reset-edit-parameter "$ASSET_ID" exposure --socket "$SOCKET")
echo "$RESET_OUT"
if ! echo "$RESET_OUT" | grep -q '"ok"'; then
    echo "ERROR: reset-edit-parameter did not return ok"
    exit 1
fi
# Wait for debounced render + auto-save (render ~50ms, save ~500ms).
sleep 1

echo "=== get-edit $ASSET_ID — assert exposure == 0.0 ==="
GET_OUT=$("$CLI_BIN" get-edit "$ASSET_ID" --socket "$SOCKET")
echo "$GET_OUT"
EXPOSURE=$(printf '%s' "$GET_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(float(doc['data']['exposure']))
")
if [ "$EXPOSURE" != "0.0" ]; then
    echo "ERROR: expected exposure == 0.0 after reset, got '$EXPOSURE'"
    exit 1
fi
echo "  OK: exposure == $EXPOSURE"

echo "=== screenshot: develop after reset ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-after-reset.png" --socket "$SOCKET" >/dev/null

# Regression guard for #100: deactivate() must flush pending edits.
# Pick a distinct value (1.5) so a pass cannot be residue of the earlier
# 2.0 check, then leave develop immediately — no sleep — so the 500ms
# debounce cannot have fired. Re-entering develop must show 1.5 from disk.
echo "=== set-edit-parameter $ASSET_ID exposure 1.5 (flush-on-navigate test) ==="
FLUSH_SET_OUT=$("$CLI_BIN" set-edit-parameter "$ASSET_ID" exposure 1.5 --socket "$SOCKET")
echo "$FLUSH_SET_OUT"
if ! echo "$FLUSH_SET_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-edit-parameter (1.5) did not return ok"
    exit 1
fi

echo "=== navigate library immediately (inside the 500ms debounce window) ==="
"$CLI_BIN" navigate library --socket "$SOCKET" >/dev/null

echo "=== navigate develop (re-entering, should load flushed value from catalog) ==="
"$CLI_BIN" navigate develop --socket "$SOCKET" >/dev/null
sleep 1

echo "=== get-edit $ASSET_ID — assert exposure == 1.5 ==="
FLUSH_GET_OUT=$("$CLI_BIN" get-edit "$ASSET_ID" --socket "$SOCKET")
echo "$FLUSH_GET_OUT"
FLUSH_EXPOSURE=$(printf '%s' "$FLUSH_GET_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(float(doc['data']['exposure']))
")
if [ "$FLUSH_EXPOSURE" != "1.5" ]; then
    echo "ERROR: expected flushed exposure == 1.5, got '$FLUSH_EXPOSURE' — deactivate() dropped the edit"
    exit 1
fi
echo "  OK: flushed exposure == $FLUSH_EXPOSURE"

echo "=== screenshot: develop after flush ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-after-flush.png" --socket "$SOCKET" >/dev/null

echo "=== navigate library (back out of develop) ==="
"$CLI_BIN" navigate library --socket "$SOCKET" >/dev/null
sleep 1

echo "=== screenshot: library after develop ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/library-after-develop.png" --socket "$SOCKET" >/dev/null

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness develop flow PASSED ==="
