#!/usr/bin/env bash
# harness-copypaste-flow.sh — Layer C flow for edit copy/paste.
#
# Boots the app in harness mode, imports fixture photos, seeds an edit state
# on asset A, copies it, pastes it onto asset B (without crop), and verifies
# the result via getEdit.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_DIR="$REPO_ROOT/.artifacts/harness-copypaste"
CATALOG_COPY="$ARTIFACT_DIR/catalog.sqlite"
ORIGINALS_DIR="$ARTIFACT_DIR/originals"
IMPORT_SOURCE="$REPO_ROOT/fixtures/import"
SOCKET="/tmp/dimroom-harness-copypaste-$$.sock"
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

# JSON numbers don't round-trip through string comparison: Swift's JSONEncoder
# writes Double(2.0) as the integer-looking `2`, Python parses it as int, and
# str(2) != "2.0". Parse both sides as floats and compare with an epsilon.
assert_json_number() {
    local label="$1" json="$2" field="$3" expected="$4"
    local actual
    actual=$(printf '%s' "$json" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
node = doc
for key in '$field'.split('.'):
    node = node[key]
print(float(node))
")
    local matches
    matches=$(/usr/bin/python3 -c "
import sys
a = float('$actual')
b = float('$expected')
print('yes' if abs(a - b) < 1e-9 else 'no')
")
    if [ "$matches" != "yes" ]; then
        echo "ERROR: $label — expected $field == $expected, got $actual"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — $field ≈ $expected"
}

assert_json_field_absent() {
    local label="$1" json="$2" field="$3"
    local present
    present=$(printf '%s' "$json" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
node = doc
keys = '$field'.split('.')
try:
    for key in keys:
        node = node[key]
    if node is None:
        print('absent')
    else:
        print('present')
except (KeyError, TypeError):
    print('absent')
")
    if [ "$present" != "absent" ]; then
        echo "ERROR: $label — expected $field to be absent or null"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — $field absent/null"
}

echo "=== Building App ==="
swift build --package-path "$REPO_ROOT/App" 2>&1

echo "=== Building CLI ==="
swift build --package-path "$REPO_ROOT/Packages/Harness" --product dimroom-cli 2>&1

APP_BIN="$REPO_ROOT/App/.build/debug/Dimroom"
CLI_BIN="$REPO_ROOT/Packages/Harness/.build/debug/dimroom-cli"

if [ ! -x "$APP_BIN" ]; then
    echo "ERROR: App binary not found at $APP_BIN"
    exit 1
fi
if [ ! -x "$CLI_BIN" ]; then
    echo "ERROR: CLI binary not found at $CLI_BIN"
    exit 1
fi

echo "=== Preparing working catalog and originals dir ==="
rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR" "$ORIGINALS_DIR"
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

echo "=== Import fixtures ==="
IMPORT_OUT=$("$CLI_BIN" import-folder "$IMPORT_SOURCE" --socket "$SOCKET")
echo "$IMPORT_OUT"
assert_json_field "import status" "$IMPORT_OUT" "status" "ok"

echo "=== List assets to get UUIDs ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"

ASSET_A=$(printf '%s' "$LIST_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(doc['data'][0]['id'])
")
ASSET_B=$(printf '%s' "$LIST_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(doc['data'][1]['id'])
")
echo "  Asset A: $ASSET_A"
echo "  Asset B: $ASSET_B"

echo "=== Set edit on asset A (exposure: 2.0, cropAngle: 5.0) ==="
SET_OUT=$("$CLI_BIN" set-edit "$ASSET_A" --json '{"exposure":2.0,"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0,"temperature":6500,"tint":0,"clarity":0,"vibrance":0,"saturation":0,"cropAngle":5.0}' --socket "$SOCKET")
echo "$SET_OUT"
assert_json_field "setEdit status" "$SET_OUT" "status" "ok"

echo "=== Copy edit from asset A ==="
COPY_OUT=$("$CLI_BIN" copy-edit "$ASSET_A" --socket "$SOCKET")
echo "$COPY_OUT"
assert_json_field "copyEdit status" "$COPY_OUT" "status" "ok"

echo "=== Paste edit onto asset B (without crop) ==="
PASTE_OUT=$("$CLI_BIN" paste-edit "$ASSET_B" --socket "$SOCKET")
echo "$PASTE_OUT"
assert_json_field "pasteEdit status" "$PASTE_OUT" "status" "ok"
assert_json_field "pasteEdit pasted" "$PASTE_OUT" "data.pasted" "True"

echo "=== Get edit for asset B ==="
GET_OUT=$("$CLI_BIN" get-edit "$ASSET_B" --socket "$SOCKET")
echo "$GET_OUT"
assert_json_field "getEdit status" "$GET_OUT" "status" "ok"
assert_json_number "getEdit exposure" "$GET_OUT" "data.exposure" "2.0"
assert_json_field_absent "getEdit cropRect" "$GET_OUT" "data.cropRect"
assert_json_field_absent "getEdit cropAngle" "$GET_OUT" "data.cropAngle"

echo "=== Screenshot ==="
"$CLI_BIN" screenshot "$ARTIFACT_DIR/copypaste-result.png" --socket "$SOCKET" || true

echo "=== Quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness copy/paste flow PASSED ==="
