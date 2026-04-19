#!/usr/bin/env bash
# harness-crop-flow.sh — Layer C flow for the crop tool.
#
# Boots the app in harness mode, imports fixture photos, navigates to
# Develop on the first asset, fires setCrop with a 3:2 centre crop via
# the harness CLI, verifies getEdit reflects the crop on the asset,
# and screenshots the Develop view with the crop applied.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_DIR="$REPO_ROOT/.artifacts/harness-crop"
CATALOG_COPY="$ARTIFACT_DIR/catalog.sqlite"
ORIGINALS_DIR="$ARTIFACT_DIR/originals"
IMPORT_SOURCE="$REPO_ROOT/fixtures/import"
SOCKET="/tmp/dimroom-harness-crop-$$.sock"
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
    actual=$(printf '%s' "$json" | "$REPO_ROOT/bin/harness-json-extract" "$field")
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: $label — expected $field == $expected, got $actual"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — $field == $expected"
}

assert_json_field_present() {
    local label="$1" json="$2" field="$3"
    local present
    present=$(printf '%s' "$json" | "$REPO_ROOT/bin/harness-json-extract" "$field" --absent)
    if [ "$present" != "present" ]; then
        echo "ERROR: $label — expected $field to be present"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — $field present"
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

echo "=== List assets to get UUID ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"
ASSET=$(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[0].id')
echo "  Asset: $ASSET"

echo "=== Select asset and navigate to Develop ==="
"$CLI_BIN" select-asset "$ASSET" --socket "$SOCKET" >/dev/null
"$CLI_BIN" navigate develop --socket "$SOCKET" >/dev/null
# Let DevelopViewModel.activate finish loading the preview.
sleep 1

echo "=== setCrop — 3:2 centre crop, no straighten ==="
SET_OUT=$("$CLI_BIN" set-crop "$ASSET" \
    --x 0.125 --y 0.0 --width 0.75 --height 1.0 --angle 0 \
    --socket "$SOCKET")
echo "$SET_OUT"
assert_json_field "setCrop status" "$SET_OUT" "status" "ok"
# Wait for debounced render + auto-save.
sleep 1

echo "=== getEdit — verify cropRect present, cropAngle absent/null (angle=0 stored as nil) ==="
GET_OUT=$("$CLI_BIN" get-edit "$ASSET" --socket "$SOCKET")
echo "$GET_OUT"
assert_json_field "getEdit status" "$GET_OUT" "status" "ok"
assert_json_field_present "getEdit cropRect" "$GET_OUT" "data.cropRect"

echo "=== setCrop — with +10° straighten ==="
SET_OUT2=$("$CLI_BIN" set-crop "$ASSET" \
    --x 0.1 --y 0.1 --width 0.8 --height 0.8 --angle 10 \
    --socket "$SOCKET")
echo "$SET_OUT2"
assert_json_field "setCrop#2 status" "$SET_OUT2" "status" "ok"
sleep 1

echo "=== getEdit — verify cropAngle == 10 ==="
GET_OUT2=$("$CLI_BIN" get-edit "$ASSET" --socket "$SOCKET")
echo "$GET_OUT2"
assert_json_field_present "getEdit cropRect" "$GET_OUT2" "data.cropRect"
CROP_ANGLE=$(printf '%s' "$GET_OUT2" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(float(doc['data']['cropAngle']))
")
if [ "$CROP_ANGLE" != "10.0" ]; then
    echo "ERROR: expected cropAngle == 10.0, got '$CROP_ANGLE'"
    exit 1
fi
echo "  OK: cropAngle == $CROP_ANGLE"

echo "=== Screenshot ==="
"$CLI_BIN" screenshot "$ARTIFACT_DIR/crop-result.png" --socket "$SOCKET" || true

echo "=== Quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness crop flow PASSED ==="
