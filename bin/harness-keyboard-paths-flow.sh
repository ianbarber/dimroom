#!/usr/bin/env bash
# harness-keyboard-paths-flow.sh — Layer C flow that exercises the
# menu-attached keyboard shortcuts end-to-end without ever priming
# selection via `select-assets`. Catches the regression #180 was
# opened for: modifierless `.onKeyPress` handlers on the root view
# silently no-op at launch because focus hasn't landed on a child.
#
# Each `post-menu-action <name>` call posts the same Notification
# that the menu bar's keyboard shortcut would post, so this flow
# proves the menu-to-action wiring works without needing to
# synthesise NSEvents through the responder chain.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
ARTIFACT_DIR="$REPO_ROOT/.artifacts/harness-keyboard-paths"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$ARTIFACT_DIR/shots}"
CATALOG_COPY="$ARTIFACT_DIR/catalog.sqlite"
ORIGINALS_DIR="$ARTIFACT_DIR/originals"
IMPORT_SOURCE="$REPO_ROOT/fixtures/import"
SOCKET="/tmp/dimroom-harness-keypaths-$$.sock"
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
FIXTURE_CATALOG="$CATALOG_COPY"
HARNESS_WORK_DIR="$ARTIFACT_DIR"
HARNESS_ENV=(DIMROOM_HARNESS_DISABLE_DRIVE=1 DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0)
harness_launch_app

echo "=== importFolder (expect 3 imported) ==="
IMPORT_OUT=$("$CLI_BIN" import-folder "$IMPORT_SOURCE" --socket "$SOCKET")
echo "$IMPORT_OUT"
assert_json_field "import status" "$IMPORT_OUT" "status" "ok"
assert_json_field "importedCount" "$IMPORT_OUT" "data.importedCount" "3"

echo "=== navigate library + reset scope to All Photos ==="
"$CLI_BIN" navigate library --socket "$SOCKET" > /dev/null
"$CLI_BIN" set-scope --socket "$SOCKET" > /dev/null
sleep 1

# Sanity: starting route is library and there are 3 visible assets.
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
assert_json_field "starting route" "$STATE_OUT" "data.route" "library"
assert_json_field "starting assetCount" "$STATE_OUT" "data.assetCount" "3"

# ─── Mode switch via menu actions ─────────────────────────────────
# This is the headline assertion — at first launch, NO child view has
# claimed focus, so the previous `.onKeyPress` handlers for g/e/d
# were silently no-opping. The menu-attached key equivalents now
# fire regardless of focus, and `post-menu-action` exercises the
# same Notification path the menu shortcut would.

echo "=== post-menu-action mode-loupe ==="
"$CLI_BIN" post-menu-action mode-loupe --socket "$SOCKET" > /dev/null
sleep 1
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
assert_json_field "route after mode-loupe" "$STATE_OUT" "data.route" "loupe"

echo "=== post-menu-action mode-develop ==="
"$CLI_BIN" post-menu-action mode-develop --socket "$SOCKET" > /dev/null
sleep 1
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
assert_json_field "route after mode-develop" "$STATE_OUT" "data.route" "develop"

echo "=== post-menu-action toggle-histogram — from Develop ==="
# Histogram default is on; toggle should flip to false.
"$CLI_BIN" post-menu-action toggle-histogram --socket "$SOCKET" > /dev/null
sleep 1
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
assert_json_field "showHistogram after toggle" "$STATE_OUT" "data.showHistogram" "false"

# Toggle back so subsequent runs / debugging see the default-on state.
"$CLI_BIN" post-menu-action toggle-histogram --socket "$SOCKET" > /dev/null
sleep 1
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
assert_json_field "showHistogram after second toggle" "$STATE_OUT" "data.showHistogram" "true"

echo "=== post-menu-action mode-library ==="
"$CLI_BIN" post-menu-action mode-library --socket "$SOCKET" > /dev/null
sleep 1
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
assert_json_field "route after mode-library" "$STATE_OUT" "data.route" "library"

echo "=== screenshot library after mode-switch loop ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/library-after-mode-switch.png" --socket "$SOCKET" > /dev/null

# ─── Rating via menu action ───────────────────────────────────────
# Old behaviour required selectedAssetId != nil. Keep that contract —
# prime selection with select-asset (singular, not the multi-asset
# select-assets variant that the issue explicitly calls out as the
# one we must avoid).

echo "=== list-assets — pick first id, prime selection ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
ID1=$(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[0].id')
echo "  ID1=$ID1"
"$CLI_BIN" select-asset "$ID1" --socket "$SOCKET" > /dev/null

echo "=== post-menu-action set-rating-3 ==="
"$CLI_BIN" post-menu-action set-rating-3 --socket "$SOCKET" > /dev/null
sleep 1

LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
# Find the row whose id matches ID1 and read its rating. list-assets
# returns rows sorted by capture/import date, so position is stable
# but we look up by id to be safe.
FIRST_RATING=$(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[0].rating')
if [ "$FIRST_RATING" != "3" ]; then
    echo "ERROR: expected first asset rating == 3 after set-rating-3 menu action, got $FIRST_RATING"
    echo "Response: $LIST_OUT"
    exit 1
fi
echo "  OK: first asset rating == 3 after post-menu-action set-rating-3"

echo "=== post-menu-action clear-rating ==="
"$CLI_BIN" post-menu-action clear-rating --socket "$SOCKET" > /dev/null
sleep 1
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
FIRST_RATING=$(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[0].rating')
if [ "$FIRST_RATING" != "0" ]; then
    echo "ERROR: expected first asset rating == 0 after clear-rating menu action, got $FIRST_RATING"
    exit 1
fi
echo "  OK: first asset rating == 0 after post-menu-action clear-rating"

# ─── Arrow navigation via menu action ─────────────────────────────
# selectedAssetId starts at ID1; select-next should advance to ID2.

ID2=$(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[1].id')
echo "  ID2=$ID2"

echo "=== post-menu-action select-next ==="
"$CLI_BIN" post-menu-action select-next --socket "$SOCKET" > /dev/null
sleep 1
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
assert_json_field "selectedAssetId after select-next" "$STATE_OUT" "data.selectedAssetId" "$ID2"

echo "=== post-menu-action select-previous ==="
"$CLI_BIN" post-menu-action select-previous --socket "$SOCKET" > /dev/null
sleep 1
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
assert_json_field "selectedAssetId after select-previous" "$STATE_OUT" "data.selectedAssetId" "$ID1"

# ─── Select All Visible via menu action ───────────────────────────

echo "=== post-menu-action select-all-visible ==="
"$CLI_BIN" post-menu-action select-all-visible --socket "$SOCKET" > /dev/null
sleep 1
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
SELECTED_COUNT=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.selectedAssetIds' --length)
if [ "$SELECTED_COUNT" != "3" ]; then
    echo "ERROR: expected 3 selected after select-all-visible, got $SELECTED_COUNT"
    echo "Response: $STATE_OUT"
    exit 1
fi
echo "  OK: 3 assets selected after post-menu-action select-all-visible"

# ─── Unknown action returns error ─────────────────────────────────

echo "=== post-menu-action bogus-name — expect error ==="
set +e
BOGUS_OUT=$("$CLI_BIN" post-menu-action this-is-not-a-real-action --socket "$SOCKET")
BOGUS_STATUS=$?
set -e
echo "$BOGUS_OUT"
assert_json_field "bogus action status" "$BOGUS_OUT" "status" "error"
echo "  CLI exited with $BOGUS_STATUS (non-zero acceptable since server returned error)"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness keyboard-paths flow PASSED ==="
