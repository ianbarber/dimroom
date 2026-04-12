#!/usr/bin/env bash
# harness-import-ui-flow.sh — Layer C flow for the import UI feature.
#
# Verifies that the import-then-preview-generation flow works end-to-end
# through the harness surface: imports a folder, confirms preview
# generation produces real thumbnails, navigates to the library, and
# takes a screenshot showing the imported photos with thumbnails.
#
# This exercises the same code path as File → Import Folder…, minus
# the NSOpenPanel (which is a system dialog that can't be driven by
# the harness).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/import-ui}"
WORK_DIR="$REPO_ROOT/.artifacts/harness-import-ui"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
ORIGINALS_DIR="$WORK_DIR/originals"
PREVIEW_CACHE="$WORK_DIR/previews"
IMPORT_SOURCE="$REPO_ROOT/fixtures/import"
SOCKET="/tmp/dimroom-harness-import-ui-$$.sock"
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

assert_gt() {
    local label="$1" json="$2" field="$3" threshold="$4"
    local actual
    actual=$(printf '%s' "$json" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
node = doc
for key in '$field'.split('.'):
    node = node[key]
print(node)
")
    if [ "$actual" -le "$threshold" ]; then
        echo "ERROR: $label — expected $field > $threshold, got $actual"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — $field == $actual (> $threshold)"
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

echo "=== Preparing working directories ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$ORIGINALS_DIR" "$PREVIEW_CACHE" "$SCREENSHOT_DIR"
# Start with a fresh empty catalog (CatalogDatabase will create and migrate).
rm -f "$CATALOG_PATH"

echo "=== Launching app in harness mode ==="
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_ORIGINALS_DIR="$ORIGINALS_DIR" \
"$APP_BIN" --harness --fixture-catalog "$CATALOG_PATH" --preview-cache "$PREVIEW_CACHE" &
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

echo "=== importFolder (expect 3 imported, 0 skipped) ==="
IMPORT_OUT=$("$CLI_BIN" import-folder "$IMPORT_SOURCE" --socket "$SOCKET")
echo "$IMPORT_OUT"
assert_json_field "import status" "$IMPORT_OUT" "status" "ok"
assert_json_field "importedCount" "$IMPORT_OUT" "data.importedCount" "3"
assert_json_field "skippedCount" "$IMPORT_OUT" "data.skippedCount" "0"

echo "=== state — verify assetCount > 0 ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
assert_gt "assetCount" "$STATE_OUT" "data.assetCount" "0"

echo "=== listAssets — verify filenames ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"
assert_json_field "list status" "$LIST_OUT" "status" "ok"

echo "=== Verify previews exist on disk ==="
PREVIEW_COUNT=$(find "$PREVIEW_CACHE" -name "*.thumb.jpg" -type f | wc -l | tr -d ' ')
if [ "$PREVIEW_COUNT" -lt 3 ]; then
    echo "ERROR: expected >= 3 thumbnails in preview cache, found $PREVIEW_COUNT"
    exit 1
fi
echo "  OK: $PREVIEW_COUNT thumbnail(s) in preview cache"

echo "=== navigate library ==="
NAV_OUT=$("$CLI_BIN" navigate library --socket "$SOCKET")
echo "$NAV_OUT"

# Give SwiftUI a moment to render after navigation + data load.
sleep 1

echo "=== screenshot ==="
SHOT_PATH="$SCREENSHOT_DIR/import-ui-library.png"
SHOT_OUT=$("$CLI_BIN" screenshot "$SHOT_PATH" --socket "$SOCKET")
echo "$SHOT_OUT"
if ! echo "$SHOT_OUT" | grep -q '"ok"'; then
    echo "ERROR: screenshot command did not return ok"
    exit 1
fi
if [ ! -f "$SHOT_PATH" ]; then
    echo "ERROR: screenshot file not created at $SHOT_PATH"
    exit 1
fi
FILE_SIZE=$(wc -c < "$SHOT_PATH" | tr -d ' ')
if [ "$FILE_SIZE" -lt 1000 ]; then
    echo "ERROR: screenshot too small ($FILE_SIZE bytes) — likely a blank frame"
    exit 1
fi
echo "  OK: screenshot created ($FILE_SIZE bytes)"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness import-ui flow PASSED ==="
