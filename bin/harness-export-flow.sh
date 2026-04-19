#!/usr/bin/env bash
# harness-export-flow.sh — Layer C flow for the export pipeline.
#
# Boots the app in harness mode, imports fixture photos, then exports
# them to a temp directory as JPEG. Verifies files exist with the
# correct extension. Exports again to the same directory and verifies
# collision naming (_1 suffixes).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_DIR="$REPO_ROOT/.artifacts/harness-export"
CATALOG_COPY="$ARTIFACT_DIR/catalog.sqlite"
ORIGINALS_DIR="$ARTIFACT_DIR/originals"
EXPORT_DIR="$ARTIFACT_DIR/exported"
IMPORT_SOURCE="$REPO_ROOT/fixtures/import"
SOCKET="/tmp/dimroom-harness-export-$$.sock"
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
rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR" "$ORIGINALS_DIR" "$EXPORT_DIR"
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

echo "=== Import fixtures (expect 3 imported) ==="
IMPORT_OUT=$("$CLI_BIN" import-folder "$IMPORT_SOURCE" --socket "$SOCKET")
echo "$IMPORT_OUT"
assert_json_field "import status" "$IMPORT_OUT" "status" "ok"
assert_json_field "import importedCount" "$IMPORT_OUT" "data.importedCount" "3"

echo "=== Clear scope to show all assets ==="
"$CLI_BIN" set-scope --socket "$SOCKET" > /dev/null

echo "=== First export to JPEG (expect 3 exported) ==="
EXPORT_OUT=$("$CLI_BIN" export "$EXPORT_DIR" --format jpeg --socket "$SOCKET")
echo "$EXPORT_OUT"
assert_json_field "first export status" "$EXPORT_OUT" "status" "ok"
assert_json_field "first export exportedCount" "$EXPORT_OUT" "data.exportedCount" "3"

echo "=== Verify 3 JPEG files exist ==="
JPG_COUNT=$(find "$EXPORT_DIR" -name "*.jpg" | wc -l | tr -d ' ')
if [ "$JPG_COUNT" -ne 3 ]; then
    echo "ERROR: Expected 3 .jpg files, found $JPG_COUNT"
    ls -la "$EXPORT_DIR"
    exit 1
fi
echo "  OK: Found $JPG_COUNT .jpg files"

echo "=== Second export to same dir (expect collision naming) ==="
EXPORT_OUT2=$("$CLI_BIN" export "$EXPORT_DIR" --format jpeg --socket "$SOCKET")
echo "$EXPORT_OUT2"
assert_json_field "second export status" "$EXPORT_OUT2" "status" "ok"
assert_json_field "second export exportedCount" "$EXPORT_OUT2" "data.exportedCount" "3"

echo "=== Verify 6 JPEG files exist (3 original + 3 with _1 suffix) ==="
JPG_COUNT2=$(find "$EXPORT_DIR" -name "*.jpg" | wc -l | tr -d ' ')
if [ "$JPG_COUNT2" -ne 6 ]; then
    echo "ERROR: Expected 6 .jpg files after second export, found $JPG_COUNT2"
    ls -la "$EXPORT_DIR"
    exit 1
fi
echo "  OK: Found $JPG_COUNT2 .jpg files after second export"

# Verify at least one _1 suffix file exists
COLLISION_COUNT=$(find "$EXPORT_DIR" -name "*_1.jpg" | wc -l | tr -d ' ')
if [ "$COLLISION_COUNT" -lt 1 ]; then
    echo "ERROR: Expected at least one _1.jpg file, found $COLLISION_COUNT"
    ls -la "$EXPORT_DIR"
    exit 1
fi
echo "  OK: Found $COLLISION_COUNT collision-named files"

echo "=== Quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness export flow PASSED ==="
