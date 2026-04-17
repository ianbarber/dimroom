#!/usr/bin/env bash
# harness-multi-select-delete-flow.sh — Layer C flow for multi-select
# + soft-delete + Recently Deleted + restore + permanent delete.
#
# Boots the app in harness mode against a fresh catalog, imports the
# 3-asset fixture folder, then drives the full delete/restore/permanent
# delete loop through the CLI and asserts the view model + catalog
# counts at each step.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_DIR="$REPO_ROOT/.artifacts/harness-multi-select-delete"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$ARTIFACT_DIR/shots}"
CATALOG_COPY="$ARTIFACT_DIR/catalog.sqlite"
ORIGINALS_DIR="$ARTIFACT_DIR/originals"
IMPORT_SOURCE="$REPO_ROOT/fixtures/import"
SOCKET="/tmp/dimroom-harness-multidel-$$.sock"
APP_PID=""

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET"
}
trap cleanup EXIT

assert_json_field() {
    local label="$1" json="$2" field="$3" expected="$4"
    local actual
    actual=$(printf '%s' "$json" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
node = doc
for key in '$field'.split('.'):
    node = node[key]
print(node)
")
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: $label — expected $field == $expected, got $actual"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — $field == $expected"
}

assert_array_length() {
    local label="$1" json="$2" field="$3" expected="$4"
    local actual
    actual=$(printf '%s' "$json" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
node = doc
for key in '$field'.split('.'):
    node = node[key]
print(len(node))
")
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: $label — expected len($field) == $expected, got $actual"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — len($field) == $expected"
}

echo "=== Building App ==="
swift build --package-path "$REPO_ROOT/App" 2>&1

echo "=== Building CLI ==="
swift build --package-path "$REPO_ROOT/Packages/Harness" --product dimroom-cli 2>&1

APP_BIN="$REPO_ROOT/App/.build/debug/Dimroom"
CLI_BIN="$REPO_ROOT/Packages/Harness/.build/debug/dimroom-cli"

for bin in "$APP_BIN" "$CLI_BIN"; do
    if [ ! -x "$bin" ]; then
        echo "ERROR: missing binary $bin"
        exit 1
    fi
done

echo "=== Preparing working catalog and originals dir ==="
rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR" "$ORIGINALS_DIR" "$SCREENSHOT_DIR"
rm -f "$CATALOG_COPY"

echo "=== Launching app in harness mode ==="
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_ORIGINALS_DIR="$ORIGINALS_DIR" \
"$APP_BIN" --harness --fixture-catalog "$CATALOG_COPY" &
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

echo "=== importFolder (expect 3 imported) ==="
IMPORT_OUT=$("$CLI_BIN" import-folder "$IMPORT_SOURCE" --socket "$SOCKET")
echo "$IMPORT_OUT"
assert_json_field "import status" "$IMPORT_OUT" "status" "ok"
assert_json_field "importedCount" "$IMPORT_OUT" "data.importedCount" "3"

echo "=== navigate library ==="
"$CLI_BIN" navigate library --socket "$SOCKET" > /dev/null
# Back to All Photos so listAssets reflects the full catalog, not the
# auto-scope set by importFolder.
"$CLI_BIN" set-scope --socket "$SOCKET" > /dev/null
sleep 1

echo "=== listAssets (expect 3 rows) ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"
assert_json_field "list status" "$LIST_OUT" "status" "ok"
assert_array_length "list length" "$LIST_OUT" "data" "3"

# Pull the first two UUIDs — the ones we'll delete.
ID1=$(printf '%s' "$LIST_OUT" | /usr/bin/python3 -c "
import json, sys
print(json.loads(sys.stdin.read())['data'][0]['id'])
")
ID2=$(printf '%s' "$LIST_OUT" | /usr/bin/python3 -c "
import json, sys
print(json.loads(sys.stdin.read())['data'][1]['id'])
")
echo "ID1=$ID1"
echo "ID2=$ID2"

echo "=== selectAssets [ID1, ID2] ==="
"$CLI_BIN" select-assets "$ID1" "$ID2" --socket "$SOCKET" > /dev/null
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
assert_array_length "selectedAssetIds" "$STATE_OUT" "data.selectedAssetIds" "2"

echo "=== deleteAssets [ID1, ID2] ==="
"$CLI_BIN" delete-assets "$ID1" "$ID2" --socket "$SOCKET" > /dev/null
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
assert_json_field "assetCount after delete" "$STATE_OUT" "data.assetCount" "1"
assert_json_field "undo toast visible" "$STATE_OUT" "data.hasUndoToast" "True"

sleep 1
echo "=== screenshot grid after delete ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/after-delete.png" --socket "$SOCKET" > /dev/null

echo "=== setScopeRecentlyDeleted — expect 2 rows ==="
"$CLI_BIN" set-scope-recently-deleted --socket "$SOCKET" > /dev/null
sleep 1
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
assert_json_field "scopeKind" "$STATE_OUT" "data.scopeKind" "recentlyDeleted"
assert_json_field "assetCount in trash" "$STATE_OUT" "data.assetCount" "2"

echo "=== screenshot Recently Deleted ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/trash.png" --socket "$SOCKET" > /dev/null

echo "=== restoreAssets [ID1] — trash drops to 1 ==="
"$CLI_BIN" restore-assets "$ID1" --socket "$SOCKET" > /dev/null
sleep 1
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
assert_json_field "trash after restore" "$STATE_OUT" "data.assetCount" "1"

echo "=== setScope all — live grid has 2 rows ==="
"$CLI_BIN" set-scope --socket "$SOCKET" > /dev/null
sleep 1
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
assert_json_field "all scope after restore" "$STATE_OUT" "data.assetCount" "2"

echo "=== permanentlyDeleteAssets [ID2] — remove from catalog ==="
"$CLI_BIN" set-scope-recently-deleted --socket "$SOCKET" > /dev/null
sleep 1
"$CLI_BIN" permanently-delete-assets "$ID2" --socket "$SOCKET" > /dev/null
sleep 1
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
assert_json_field "trash empty after permanent delete" "$STATE_OUT" "data.assetCount" "0"

# listAssets (which uses the live filter — no soft-deleted) should now
# return 2 rows (ID1 restored, ID3 never touched, ID2 gone forever).
echo "=== listAssets — 2 rows remain (ID1 restored, ID3 untouched) ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
assert_array_length "final list length" "$LIST_OUT" "data" "2"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness multi-select / delete flow PASSED ==="
