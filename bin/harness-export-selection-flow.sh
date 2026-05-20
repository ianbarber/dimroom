#!/usr/bin/env bash
# harness-export-selection-flow.sh — Layer C flow for selection-aware export.
#
# Boots the app in harness mode, imports the three fixture photos, then:
#   1. With no prior selection (fresh process), exports to dir A and
#      asserts all 3 land (fallback-to-visible branch).
#   2. Selects a single asset and exports to dir B, asserts exactly 1
#      file lands with the expected stem (selection branch).
# Complements harness-export-flow.sh, which covers the fallback branch
# plus collision naming in depth.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_DIR="$REPO_ROOT/.artifacts/harness-export-selection"
CATALOG_COPY="$ARTIFACT_DIR/catalog.sqlite"
ORIGINALS_DIR="$ARTIFACT_DIR/originals"
EXPORT_DIR_ALL="$ARTIFACT_DIR/exported-all"
EXPORT_DIR_ONE="$ARTIFACT_DIR/exported-one"
IMPORT_SOURCE="$REPO_ROOT/fixtures/import"
SOCKET="/tmp/dimroom-harness-export-selection-$$.sock"
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
mkdir -p "$ARTIFACT_DIR" "$ORIGINALS_DIR" "$EXPORT_DIR_ALL" "$EXPORT_DIR_ONE"
rm -f "$CATALOG_COPY"

echo "=== Launching app in harness mode ==="
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_HARNESS_DISABLE_DRIVE=1 \
DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0 \
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

echo "=== Fallback branch: export with no selection (expect all 3) ==="
EXPORT_OUT_ALL=$("$CLI_BIN" export "$EXPORT_DIR_ALL" --format jpeg --socket "$SOCKET")
echo "$EXPORT_OUT_ALL"
assert_json_field "fallback export status" "$EXPORT_OUT_ALL" "status" "ok"
assert_json_field "fallback export exportedCount" "$EXPORT_OUT_ALL" "data.exportedCount" "3"

JPG_COUNT_ALL=$(find "$EXPORT_DIR_ALL" -name "*.jpg" | wc -l | tr -d ' ')
if [ "$JPG_COUNT_ALL" -ne 3 ]; then
    echo "ERROR: Expected 3 .jpg files in fallback export, found $JPG_COUNT_ALL"
    ls -la "$EXPORT_DIR_ALL"
    exit 1
fi
echo "  OK: fallback export produced $JPG_COUNT_ALL .jpg files"

echo "=== Fetch asset list to pick a selection target ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
# Zip parallel id/originalFilename streams from the same LIST_OUT so the
# order lines up, then pick the id whose filename matches.
TARGET_ID=$(paste \
    <(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[*].id') \
    <(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[*].originalFilename') \
    | awk -F'\t' '$2 == "IMG_0002.jpg" { print $1; exit }')
if [ -z "$TARGET_ID" ]; then
    echo "ERROR: could not find IMG_0002.jpg in list-assets output"
    echo "$LIST_OUT"
    exit 1
fi
echo "  Selecting asset id $TARGET_ID (IMG_0002.jpg)"

echo "=== Select the single target asset ==="
"$CLI_BIN" select-asset "$TARGET_ID" --socket "$SOCKET" > /dev/null

# When the capture-screenshots skill runs the flow, $SCREENSHOT_DIR is
# set to the per-flow output directory. Grab a library shot showing the
# selected cell so reviewers can see the input state visually.
if [ -n "${SCREENSHOT_DIR:-}" ]; then
    mkdir -p "$SCREENSHOT_DIR"
    "$CLI_BIN" screenshot "$SCREENSHOT_DIR/library-with-selection.png" --socket "$SOCKET" > /dev/null || true
fi

echo "=== Selection branch: export with selection (expect exactly 1) ==="
EXPORT_OUT_ONE=$("$CLI_BIN" export "$EXPORT_DIR_ONE" --format jpeg --socket "$SOCKET")
echo "$EXPORT_OUT_ONE"
assert_json_field "selection export status" "$EXPORT_OUT_ONE" "status" "ok"
assert_json_field "selection export exportedCount" "$EXPORT_OUT_ONE" "data.exportedCount" "1"

JPG_COUNT_ONE=$(find "$EXPORT_DIR_ONE" -name "*.jpg" | wc -l | tr -d ' ')
if [ "$JPG_COUNT_ONE" -ne 1 ]; then
    echo "ERROR: Expected 1 .jpg file in selection export, found $JPG_COUNT_ONE"
    ls -la "$EXPORT_DIR_ONE"
    exit 1
fi
echo "  OK: selection export produced $JPG_COUNT_ONE .jpg file"

# Filename stem matches the selected original (minus extension).
if ! find "$EXPORT_DIR_ONE" -name "IMG_0002*.jpg" | grep -q .; then
    echo "ERROR: expected IMG_0002*.jpg in selection export dir"
    ls -la "$EXPORT_DIR_ONE"
    exit 1
fi
echo "  OK: selection export contains the selected asset by filename"

echo "=== Quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness export-selection flow PASSED ==="
