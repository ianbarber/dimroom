#!/usr/bin/env bash
# harness-develop-undo-thumbnail-flow.sh — Layer C flow for issue #185.
#
# Regression guard for the undo/redo path of the
# regenerate-on-edit work from #184. Edits exposure in Develop, waits
# for the auto-save + regen, then fires Cmd+Z undo and asserts the
# cached thumbnail bytes change again — i.e. `reloadEditState` triggers
# a fresh regen rather than leaving the post-edit thumb in place.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/develop-undo-thumbnail}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-develop-undo-thumbnail"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
# Scope the originals staging dir + LRU originals cache under $WORK_DIR so
# any originals fetch writes its downloads + index.json here, never into the
# user's real ~/Library/Application Support/Dimroom/originals (issue #331).
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-develop-undo-thumbnail-$$.sock"
APP_PID=""

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET"
}
trap cleanup EXIT

APP_BIN="$REPO_ROOT/App/.build/debug/Dimroom"
CLI_BIN="$REPO_ROOT/Packages/Harness/.build/debug/dimroom-cli"
FIXTURE_BIN="$REPO_ROOT/Packages/Harness/.build/debug/dimroom-fixture"

for bin in "$APP_BIN" "$CLI_BIN" "$FIXTURE_BIN"; do
    if [ ! -x "$bin" ]; then
        echo "ERROR: missing binary $bin — capture-screenshots skill should have built it"
        exit 1
    fi
done

echo "=== Seeding catalog from $SEED_SRC ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$ORIGINALS_CACHE"
"$FIXTURE_BIN" seed \
    --catalog "$CATALOG_PATH" \
    --cache "$PREVIEW_CACHE" \
    --seed-dir "$SEED_SRC"

if [ ! -f "$CATALOG_PATH" ]; then
    echo "ERROR: dimroom-fixture did not produce $CATALOG_PATH"
    exit 1
fi

echo "=== Launching app in harness mode ==="
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_HARNESS_DISABLE_DRIVE=1 \
DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0 \
DIMROOM_ORIGINALS_DIR="$ORIGINALS_CACHE" \
    "$APP_BIN" --harness \
    --fixture-catalog "$CATALOG_PATH" \
    --preview-cache "$PREVIEW_CACHE" \
    --originals-cache "$ORIGINALS_CACHE" &
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

mkdir -p "$SCREENSHOT_DIR"

echo "=== navigate library ==="
"$CLI_BIN" navigate library --socket "$SOCKET" >/dev/null

echo "=== list-assets — pick first asset id ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
ASSET_ID=$(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[0].id')
if [ -z "$ASSET_ID" ]; then
    echo "ERROR: failed to extract asset id from list-assets"
    exit 1
fi
echo "  Picked asset id: $ASSET_ID"

echo "=== select-asset $ASSET_ID ==="
"$CLI_BIN" select-asset "$ASSET_ID" --socket "$SOCKET" >/dev/null

echo "=== get-preview-signature $ASSET_ID (original) ==="
SIG_ORIG_OUT=$("$CLI_BIN" get-preview-signature "$ASSET_ID" --socket "$SOCKET")
SIG_ORIG=$(printf '%s' "$SIG_ORIG_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.sha256')
if [ -z "$SIG_ORIG" ]; then
    echo "ERROR: failed to extract original sha256"
    exit 1
fi
echo "  thumbnail sha256 original: $SIG_ORIG"

echo "=== navigate develop ==="
"$CLI_BIN" navigate develop --socket "$SOCKET" >/dev/null
sleep 1

echo "=== set-edit-parameter $ASSET_ID exposure 2.0 ==="
SET_OUT=$("$CLI_BIN" set-edit-parameter "$ASSET_ID" exposure 2.0 --socket "$SOCKET")
if ! echo "$SET_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-edit-parameter did not return ok"
    echo "$SET_OUT"
    exit 1
fi
# Wait for 500ms debounce + catalog save + EditEngine regenerate.
sleep 2

echo "=== get-preview-signature $ASSET_ID (after edit) ==="
SIG_EDIT_OUT=$("$CLI_BIN" get-preview-signature "$ASSET_ID" --socket "$SOCKET")
SIG_EDIT=$(printf '%s' "$SIG_EDIT_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.sha256')
if [ -z "$SIG_EDIT" ]; then
    echo "ERROR: failed to extract post-edit sha256"
    exit 1
fi
echo "  thumbnail sha256 after edit: $SIG_EDIT"

if [ "$SIG_ORIG" = "$SIG_EDIT" ]; then
    echo "ERROR: thumbnail signature unchanged after exposure edit — #184 regression"
    exit 1
fi
echo "  OK: edit regen ran (orig != edit)"

echo "=== undo ==="
UNDO_OUT=$("$CLI_BIN" undo --socket "$SOCKET")
if ! echo "$UNDO_OUT" | grep -q '"ok"'; then
    echo "ERROR: undo did not return ok"
    echo "$UNDO_OUT"
    exit 1
fi
# Wait for the detached regen fired by reloadEditState to write the
# new thumbnail bytes.
sleep 2

echo "=== get-preview-signature $ASSET_ID (after undo) ==="
SIG_UNDO_OUT=$("$CLI_BIN" get-preview-signature "$ASSET_ID" --socket "$SOCKET")
SIG_UNDO=$(printf '%s' "$SIG_UNDO_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.sha256')
if [ -z "$SIG_UNDO" ]; then
    echo "ERROR: failed to extract post-undo sha256"
    exit 1
fi
echo "  thumbnail sha256 after undo: $SIG_UNDO"

if [ "$SIG_UNDO" = "$SIG_EDIT" ]; then
    echo "ERROR: thumbnail signature unchanged after undo — reloadEditState did not regenerate"
    exit 1
fi
echo "  OK: undo regen ran (undo != edit)"

echo "=== navigate library ==="
"$CLI_BIN" navigate library --socket "$SOCKET" >/dev/null
sleep 1

echo "=== screenshot: library after undo ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/library-after-undo.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/library-after-undo.png" ]; then
    echo "ERROR: library-after-undo screenshot not created"
    exit 1
fi

echo "=== navigate loupe ==="
"$CLI_BIN" navigate loupe --socket "$SOCKET" >/dev/null
sleep 1

echo "=== screenshot: loupe after undo ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/loupe-after-undo.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/loupe-after-undo.png" ]; then
    echo "ERROR: loupe-after-undo screenshot not created"
    exit 1
fi

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness develop-undo-thumbnail flow PASSED ==="
