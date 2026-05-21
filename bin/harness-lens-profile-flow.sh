#!/usr/bin/env bash
# harness-lens-profile-flow.sh — Layer C flow exercising the per-lens
# CA / vignette auto-correct path added in #253.
#
# Seeds a throwaway catalog with assets stamped to the bundled
# RF 50mm F1.2 L USM lens model, enters Develop, toggles
# chromaticAberration and lensVignette, and captures screenshots that
# show the profile-driven correction taking effect. The companion
# harness-develop-geometry-flow.sh already covers the no-profile
# (unknown-lens) fallback path with the same flags.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set
# by the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/lens-profile}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-lens-profile"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-lens-profile-$$.sock"
APP_PID=""
LENS_MODEL="RF 50mm F1.2 L USM"

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

echo "=== Seeding catalog from $SEED_SRC with lens model '$LENS_MODEL' ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
"$FIXTURE_BIN" seed \
    --catalog "$CATALOG_PATH" \
    --cache "$PREVIEW_CACHE" \
    --seed-dir "$SEED_SRC" \
    --lens-model "$LENS_MODEL"

if [ ! -f "$CATALOG_PATH" ]; then
    echo "ERROR: dimroom-fixture did not produce $CATALOG_PATH"
    exit 1
fi

echo "=== Launching app in harness mode ==="
DIMROOM_HARNESS_SOCKET="$SOCKET" \
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

echo "=== navigate develop ==="
"$CLI_BIN" navigate develop --socket "$SOCKET" >/dev/null
sleep 1

drive_flag() {
    local flag="$1"
    local value="$2"
    local set_out
    set_out=$("$CLI_BIN" set-edit-flag "$ASSET_ID" "$flag" "$value" --socket "$SOCKET")
    if ! echo "$set_out" | grep -q '"ok"'; then
        echo "ERROR: set-edit-flag $flag $value did not return ok"
        echo "$set_out"
        exit 1
    fi
    sleep 1
    local get_out actual
    get_out=$("$CLI_BIN" get-edit "$ASSET_ID" --socket "$SOCKET")
    actual=$(printf '%s' "$get_out" | "$REPO_ROOT/bin/harness-json-extract" "data.$flag")
    if [ "$actual" != "$value" ]; then
        echo "ERROR: expected $flag == $value, got '$actual'"
        exit 1
    fi
    echo "  OK: $flag == $actual"
}

echo "=== identity screenshot (profile resolved, flags off) ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/lens-profile-identity.png" --socket "$SOCKET" >/dev/null

echo "=== chromatic aberration on (profile-driven) ==="
drive_flag chromaticAberration true
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/lens-profile-ca-on.png" --socket "$SOCKET" >/dev/null

echo "=== lens vignette on (profile-driven) ==="
drive_flag lensVignette true
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/lens-profile-both-on.png" --socket "$SOCKET" >/dev/null

echo "=== reset both flags ==="
drive_flag chromaticAberration false
drive_flag lensVignette false

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi

echo "OK harness-lens-profile-flow.sh"
