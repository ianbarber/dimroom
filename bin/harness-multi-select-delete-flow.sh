#!/usr/bin/env bash
# harness-multi-select-delete-flow.sh — Layer C flow for multi-select
# + soft-delete + Recently Deleted + restore + permanent delete.
#
# Boots the app in harness mode against a fresh catalog, imports the
# 3-asset fixture folder, then drives the full delete/restore/permanent
# delete loop through the CLI and asserts the view model + catalog
# counts at each step.
#
# Edit-menu assertions (issue #183): after the import we also probe the
# main menu via the `inspect-menu` harness command and confirm:
#   1. an Edit menu item titled "Delete Selected" exists,
#   2. its key equivalent is Backspace (KeyEquivalent.delete, which
#      bridges to U+0008 in NSMenuItem.keyEquivalent — see the
#      `assert_menu_item_key_equivalent_hex` note below) with no
#      modifier mask, and
#   3. its initial `isEnabled` value is `false` when nothing is selected
#      (proves the `.disabled(libraryViewModel.selectedAssetIds.isEmpty
#      || router.route != .library)` binding is wired up — if anyone
#      dropped `.disabled(...)` the item would render enabled).
# This closes the regression gap PR #179 left open (#134's plan
# promised an `osascript`-driven Edit menu check that never landed).
# We use the in-process `inspect-menu` command rather than driving
# System Events via `osascript` because:
#   - in-process inspection requires no Accessibility permission and
#     therefore works headlessly in CI without an interactive grant;
#   - it reads exactly the `NSApplication.mainMenu` SwiftUI populates
#     from `.commands`, so the assertions can't be fooled by a stale
#     Accessibility cache;
#   - it is far faster and deterministic.
#
# What we deliberately do NOT assert: that the menu item flips from
# disabled to enabled *after* a selection is made later in the flow.
# SwiftUI re-renders its `.commands` tree (and pushes the new
# `.disabled(...)` value onto NSMenuItem.isEnabled) only when the scene
# is being updated by a real UI cycle. In the harness we run
# headlessly without a foreground window, so the menu state SwiftUI
# rendered at scene creation is the only one we can reliably read —
# `submenu.update()` plus a runloop spin plus `NSApp.activate(...)`
# were all tried and none of them cause SwiftUI to flush a fresh
# command-tree render in this configuration. The data-side delete loop
# below (selectAssets → deleteAssets → undo toast → recently-deleted
# scope → restore → permanent delete) still exercises every path the
# Backspace-driven menu action would hit, so a regression that broke
# the actual delete dispatch would surface there. The screenshot
# fallback suggested in #183 (writing the opened Edit menu to
# .artifacts/.../shots/edit-menu.png for visual review) is not needed:
# the static menu-shape assertions above already catch the two
# regressions the issue calls out (DeleteMenuItem dropped from
# `.commands`, or its `.keyboardShortcut(.delete)` removed).
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

# inspect-menu returns a list of {title, keyEquivalent, modifierMask,
# isEnabled, isSeparator}. Find an item by title and compare one field
# against an expected literal. Booleans/ints/strings all print verbatim.
assert_menu_item_field() {
    local label="$1" json="$2" item_title="$3" field="$4" expected="$5"
    local actual
    actual=$(printf '%s' "$json" | python3 -c "
import json, sys
resp = json.load(sys.stdin)
items = resp.get('data', {}).get('items', [])
for it in items:
    if it.get('title') == sys.argv[1]:
        v = it.get(sys.argv[2])
        if isinstance(v, bool):
            print('true' if v else 'false')
        else:
            print(v)
        sys.exit(0)
sys.exit(3)
" "$item_title" "$field") || {
        echo "ERROR: $label — menu item '$item_title' not found"
        echo "Response: $json"
        exit 1
    }
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: $label — expected '$item_title'.$field == $expected, got $actual"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — '$item_title'.$field == $expected"
}

# Like assert_menu_item_field, but prints the keyEquivalent as a
# hex codepoint so the assertion isn't sensitive to terminal /
# JSON-escaping quirks. SwiftUI's KeyEquivalent.delete bridges to the
# Mac "Delete" key (Backspace, U+0008) in NSMenuItem.keyEquivalent —
# not the forward-delete character U+007F, despite the SwiftUI name.
assert_menu_item_key_equivalent_hex() {
    local label="$1" json="$2" item_title="$3" expected_hex="$4"
    local actual
    actual=$(printf '%s' "$json" | python3 -c "
import json, sys
resp = json.load(sys.stdin)
items = resp.get('data', {}).get('items', [])
for it in items:
    if it.get('title') == sys.argv[1]:
        ke = it.get('keyEquivalent', '')
        if len(ke) != 1:
            print('len=%d' % len(ke))
        else:
            print('%04X' % ord(ke))
        sys.exit(0)
sys.exit(3)
" "$item_title") || {
        echo "ERROR: $label — menu item '$item_title' not found"
        echo "Response: $json"
        exit 1
    }
    if [ "$actual" != "$expected_hex" ]; then
        echo "ERROR: $label — expected '$item_title'.keyEquivalent codepoint == $expected_hex, got $actual"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — '$item_title'.keyEquivalent codepoint == U+$expected_hex"
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
ID1=$(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[0].id')
ID2=$(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[1].id')
echo "ID1=$ID1"
echo "ID2=$ID2"

# --- Edit-menu introspection (issue #183) ---
# Empty selection: Delete Selected exists, Backspace shortcut, no modifiers,
# disabled (selection is empty).
echo "=== inspect-menu Edit (no selection — Delete Selected should be DISABLED) ==="
MENU_OUT=$("$CLI_BIN" inspect-menu Edit --socket "$SOCKET")
echo "$MENU_OUT"
assert_json_field "inspect-menu status" "$MENU_OUT" "status" "ok"
assert_menu_item_field "Delete Selected exists" "$MENU_OUT" "Delete Selected" "title" "Delete Selected"
assert_menu_item_key_equivalent_hex "Delete Selected key" "$MENU_OUT" "Delete Selected" "0008"
assert_menu_item_field "Delete Selected modifier mask" "$MENU_OUT" "Delete Selected" "modifierMask" "0"
assert_menu_item_field "Delete Selected disabled" "$MENU_OUT" "Delete Selected" "isEnabled" "false"

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
assert_json_field "undo toast visible" "$STATE_OUT" "data.hasUndoToast" "true"

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
