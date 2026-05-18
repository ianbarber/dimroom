#!/usr/bin/env bash
# harness-develop-thumbnail-flow.sh — Layer C flow for issue #129.
#
# Verifies that editing in Develop re-renders the cached thumbnail +
# preview, so returning to Library / Loupe reflects the edited look.
# The check compares SHA-256 signatures of the cached thumbnail JPEG
# before and after setting exposure = 2.0, using the new
# `get-preview-signature` harness command.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/develop-thumbnail}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-develop-thumbnail"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-develop-thumbnail-$$.sock"
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
mkdir -p "$WORK_DIR"
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
    "$APP_BIN" --harness \
    --fixture-catalog "$CATALOG_PATH" \
    --preview-cache "$PREVIEW_CACHE" &
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

echo "=== screenshot: library before edit ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/library-before-edit.png" --socket "$SOCKET" >/dev/null

echo "=== get-preview-signature $ASSET_ID (before) ==="
SIG_BEFORE_OUT=$("$CLI_BIN" get-preview-signature "$ASSET_ID" --socket "$SOCKET")
echo "$SIG_BEFORE_OUT"
SIG_BEFORE=$(printf '%s' "$SIG_BEFORE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.sha256')
if [ -z "$SIG_BEFORE" ]; then
    echo "ERROR: failed to extract pre-edit sha256"
    exit 1
fi
echo "  thumbnail sha256 before: $SIG_BEFORE"

echo "=== navigate develop ==="
"$CLI_BIN" navigate develop --socket "$SOCKET" >/dev/null
sleep 1

echo "=== set-edit-parameter $ASSET_ID exposure 2.0 ==="
SET_OUT=$("$CLI_BIN" set-edit-parameter "$ASSET_ID" exposure 2.0 --socket "$SOCKET")
if ! echo "$SET_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-edit-parameter did not return ok"
    exit 1
fi
# Wait for 500ms debounce + catalog save + EditEngine regenerate.
sleep 2

echo "=== navigate library ==="
"$CLI_BIN" navigate library --socket "$SOCKET" >/dev/null
sleep 1

echo "=== screenshot: library after edit ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/library-after-edit.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/library-after-edit.png" ]; then
    echo "ERROR: library-after-edit screenshot not created"
    exit 1
fi

echo "=== get-preview-signature $ASSET_ID (after) ==="
SIG_AFTER_OUT=$("$CLI_BIN" get-preview-signature "$ASSET_ID" --socket "$SOCKET")
echo "$SIG_AFTER_OUT"
SIG_AFTER=$(printf '%s' "$SIG_AFTER_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.sha256')
if [ -z "$SIG_AFTER" ]; then
    echo "ERROR: failed to extract post-edit sha256"
    exit 1
fi
echo "  thumbnail sha256 after:  $SIG_AFTER"

if [ "$SIG_BEFORE" = "$SIG_AFTER" ]; then
    echo "ERROR: thumbnail signature unchanged after exposure edit — cache was not regenerated"
    exit 1
fi
echo "  OK: thumbnail bytes changed"

# Issue #186 — generational JPEG loss check. A second save of the same
# EditState must produce a byte-identical thumbnail. Under the original
# bug, regen #2 would re-encode the result of regen #1 and the SHA would
# drift on every cycle. Under the master/display tier fix, regen always
# reads from the untouched master so the second pass is bit-stable.
echo "=== navigate develop (second pass) ==="
"$CLI_BIN" navigate develop --socket "$SOCKET" >/dev/null
sleep 1

echo "=== set-edit-parameter $ASSET_ID exposure 2.0 (second pass) ==="
SET_OUT2=$("$CLI_BIN" set-edit-parameter "$ASSET_ID" exposure 2.0 --socket "$SOCKET")
if ! echo "$SET_OUT2" | grep -q '"ok"'; then
    echo "ERROR: set-edit-parameter (second pass) did not return ok"
    exit 1
fi
sleep 2

echo "=== get-preview-signature $ASSET_ID (after second regen) ==="
SIG_AFTER_2_OUT=$("$CLI_BIN" get-preview-signature "$ASSET_ID" --socket "$SOCKET")
echo "$SIG_AFTER_2_OUT"
SIG_AFTER_2=$(printf '%s' "$SIG_AFTER_2_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.sha256')
if [ -z "$SIG_AFTER_2" ]; then
    echo "ERROR: failed to extract second-regen sha256"
    exit 1
fi
echo "  thumbnail sha256 after second regen: $SIG_AFTER_2"

if [ "$SIG_AFTER" != "$SIG_AFTER_2" ]; then
    echo "ERROR: regen #2 produced different bytes than regen #1 — generational JPEG loss (issue #186)"
    exit 1
fi
echo "  OK: byte-identical across repeated regens (no generational loss)"

echo "=== navigate loupe ==="
"$CLI_BIN" navigate loupe --socket "$SOCKET" >/dev/null
sleep 1

echo "=== screenshot: loupe after edit ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/loupe-after-edit.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/loupe-after-edit.png" ]; then
    echo "ERROR: loupe-after-edit screenshot not created"
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

echo "=== Harness develop-thumbnail flow PASSED ==="
