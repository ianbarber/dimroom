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
EXPORT_DIR_MENU="$ARTIFACT_DIR/exported-menu"
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
mkdir -p "$ARTIFACT_DIR" "$ORIGINALS_DIR" "$EXPORT_DIR" "$EXPORT_DIR_MENU"
rm -f "$CATALOG_COPY"

echo "=== Launching app in harness mode ==="
# DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0 short-circuits the first-launch
# catalog-restore alert path introduced by #234 (offerConnectForRestore
# runs an NSAlert.runModal that otherwise blocks the launch when there's
# no Drive auth and no local catalog).
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_ORIGINALS_DIR="$ORIGINALS_DIR" \
DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0 \
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
assert_json_field "first export skippedCount" "$EXPORT_OUT" "data.skippedCount" "0"
assert_json_field "first export failedCount" "$EXPORT_OUT" "data.failedCount" "0"

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
assert_json_field "second export skippedCount" "$EXPORT_OUT2" "data.skippedCount" "0"
assert_json_field "second export failedCount" "$EXPORT_OUT2" "data.failedCount" "0"

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

# ----------------------------------------------------------------------
# Menu → sheet → coordinator end-to-end (regression test for #242).
#
# `export` above drives the coordinator directly; this stanza exercises
# the same path the menu's File → Export… item takes: notification →
# ContentView's exportSheetPublisher → showExportSheet → onExport
# closure → AppDelegate.startExport → ExportCoordinator. Previously the
# coordinator was reached two different ways (UI vs. harness), so a
# regression that dropped the sheet presentation looked identical to
# "nothing happened" without surfacing as a harness failure.
# ----------------------------------------------------------------------
# When the capture-screenshots skill runs the flow, $SCREENSHOT_DIR is
# set to the per-flow output directory. Grab a library-after-export shot
# so reviewers can see the state before exercising the menu path.
if [ -n "${SCREENSHOT_DIR:-}" ]; then
    mkdir -p "$SCREENSHOT_DIR"
    "$CLI_BIN" screenshot "$SCREENSHOT_DIR/library-after-direct-export.png" --socket "$SOCKET" > /dev/null || true
fi

echo "=== Pre-select an asset so the confirmation dialog stays out of the way ==="
TARGET_ID=$(printf '%s' "$(\
    "$CLI_BIN" list-assets --socket "$SOCKET" \
)" | "$REPO_ROOT/bin/harness-json-extract" 'data[0].id')
if [ -z "$TARGET_ID" ]; then
    echo "ERROR: list-assets returned no ids"
    exit 1
fi
echo "  Selecting asset $TARGET_ID"
"$CLI_BIN" select-asset "$TARGET_ID" --socket "$SOCKET" > /dev/null

echo "=== Trigger File → Export menu via notification ==="
TRIGGER_OUT=$("$CLI_BIN" trigger-export-menu --socket "$SOCKET")
if [ -n "${SCREENSHOT_DIR:-}" ]; then
    "$CLI_BIN" screenshot "$SCREENSHOT_DIR/export-sheet-visible.png" --socket "$SOCKET" > /dev/null || true
fi
echo "$TRIGGER_OUT"
assert_json_field "trigger-export-menu status" "$TRIGGER_OUT" "status" "ok"
# The export-sheet visibility flag is what proves the sheet mounted
# rather than being silently dropped (the #242 regression). The
# selection branch should bypass the confirmation dialog and land
# directly on the sheet.
assert_json_field "trigger-export-menu sheet visible" "$TRIGGER_OUT" "data.exportSheetVisible" "true"

echo "=== Complete the export sheet (substitutes for NSOpenPanel) ==="
MENU_EXPORT_OUT=$("$CLI_BIN" complete-export-sheet "$EXPORT_DIR_MENU" --format jpeg --socket "$SOCKET")
echo "$MENU_EXPORT_OUT"
assert_json_field "menu export status" "$MENU_EXPORT_OUT" "status" "ok"
# 1 because we pre-selected a single asset; selection wins over the
# fallback-to-visible branch.
assert_json_field "menu export exportedCount" "$MENU_EXPORT_OUT" "data.exportedCount" "1"
assert_json_field "menu export skippedCount" "$MENU_EXPORT_OUT" "data.skippedCount" "0"
assert_json_field "menu export failedCount" "$MENU_EXPORT_OUT" "data.failedCount" "0"

MENU_JPG_COUNT=$(find "$EXPORT_DIR_MENU" -name "*.jpg" | wc -l | tr -d ' ')
if [ "$MENU_JPG_COUNT" -ne 1 ]; then
    echo "ERROR: Expected 1 .jpg file in menu export, found $MENU_JPG_COUNT"
    ls -la "$EXPORT_DIR_MENU"
    exit 1
fi
echo "  OK: menu-driven export produced $MENU_JPG_COUNT .jpg file"

echo "=== Quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness export flow PASSED ==="
