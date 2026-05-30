#!/usr/bin/env bash
# harness-import-flow.sh — Layer C flow for the ImportKit folder importer.
#
# Boots the app in harness mode against a fresh copy of the empty fixture
# catalog, sends importFolder → listAssets → importFolder through the CLI,
# and asserts the counts match what FolderImporter is supposed to produce.
# This is the end-to-end check that the harness surface can drive a real
# import against a real on-disk catalog.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
ARTIFACT_DIR="$REPO_ROOT/.artifacts/harness-import"
CATALOG_COPY="$ARTIFACT_DIR/catalog.sqlite"
ORIGINALS_DIR="$ARTIFACT_DIR/originals"
IMPORT_SOURCE="$REPO_ROOT/fixtures/import"
SOCKET="/tmp/dimroom-harness-import-$$.sock"
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

assert_array_length() {
    local label="$1" json="$2" field="$3" expected="$4"
    local actual
    actual=$(printf '%s' "$json" | "$REPO_ROOT/bin/harness-json-extract" "$field" --length)
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
# CatalogDatabase(path:) will open or create the file and run migrations.
# Starting from a missing file guarantees a clean empty catalog regardless
# of the committed fixtures/empty.sqlite contents.
rm -f "$CATALOG_COPY"

echo "=== Launching app in harness mode ==="
FIXTURE_CATALOG="$CATALOG_COPY"
HARNESS_WORK_DIR="$ARTIFACT_DIR"
HARNESS_ENV=(DIMROOM_HARNESS_DISABLE_DRIVE=1 DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0)
harness_launch_app

echo "=== First importFolder (expect 3 imported, 0 skipped) ==="
FIRST_OUT=$("$CLI_BIN" import-folder "$IMPORT_SOURCE" --socket "$SOCKET")
echo "$FIRST_OUT"
assert_json_field "first import status" "$FIRST_OUT" "status" "ok"
assert_json_field "first import importedCount" "$FIRST_OUT" "data.importedCount" "3"
assert_json_field "first import skippedCount" "$FIRST_OUT" "data.skippedCount" "0"

echo "=== listAssets (expect 3 rows) ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"
assert_json_field "list status" "$LIST_OUT" "status" "ok"
assert_array_length "list length" "$LIST_OUT" "data" "3"

echo "=== Second importFolder (expect 0 imported, 3 skipped — dedup) ==="
SECOND_OUT=$("$CLI_BIN" import-folder "$IMPORT_SOURCE" --socket "$SOCKET")
echo "$SECOND_OUT"
assert_json_field "second import status" "$SECOND_OUT" "status" "ok"
assert_json_field "second import importedCount" "$SECOND_OUT" "data.importedCount" "0"
assert_json_field "second import skippedCount" "$SECOND_OUT" "data.skippedCount" "3"

echo "=== Quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness import flow PASSED ==="
