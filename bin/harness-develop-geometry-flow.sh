#!/usr/bin/env bash
# harness-develop-geometry-flow.sh — Layer C flow for the new Geometry
# (perspective + lens corrections) group in Develop.
#
# Seeds a throwaway catalog, launches the app in harness mode, enters Develop
# on the first asset, drives the three perspective sliders + two lens
# correction flags, asserts get-edit round-trips each value, and captures
# before/after screenshots for human review.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set by
# the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/develop-geometry}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-develop-geometry"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
# Scope the originals staging dir + LRU originals cache under $WORK_DIR so
# any originals fetch writes its downloads + index.json here, never into the
# user's real ~/Library/Application Support/Dimroom/originals (issue #331).
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-develop-geometry-$$.sock"
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
FIXTURE_CATALOG="$CATALOG_PATH"
HARNESS_WORK_DIR="$WORK_DIR"
harness_launch_app

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

# drive_param <parameter> <value> — set the parameter, wait for debounced
# render, then assert get-edit reports the value.
drive_param() {
    local param="$1"
    local value="$2"
    local set_out
    # --socket must precede the positional value or a negative value is parsed
    # as a short flag by ArgumentParser.
    set_out=$("$CLI_BIN" set-edit-parameter "$ASSET_ID" "$param" --socket "$SOCKET" -- "$value")
    if ! echo "$set_out" | grep -q '"ok"'; then
        echo "ERROR: set-edit-parameter $param $value did not return ok"
        echo "$set_out"
        exit 1
    fi
    sleep 1
    local get_out actual
    get_out=$("$CLI_BIN" get-edit "$ASSET_ID" --socket "$SOCKET")
    actual=$(printf '%s' "$get_out" | "$REPO_ROOT/bin/harness-json-extract" "data.$param")
    local actual_f expected_f
    actual_f=$(/usr/bin/python3 -c "import sys; print(float(sys.argv[1]))" "$actual")
    expected_f=$(/usr/bin/python3 -c "import sys; print(float(sys.argv[1]))" "$value")
    if [ "$actual_f" != "$expected_f" ]; then
        echo "ERROR: expected $param == $expected_f, got '$actual_f'"
        exit 1
    fi
    echo "  OK: $param == $actual_f"
}

# drive_flag <flag> <true|false> — set a boolean flag, wait for debounced
# save, then assert get-edit reports the value.
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

echo "=== identity screenshot ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-geometry-identity.png" --socket "$SOCKET" >/dev/null

echo "=== vertical keystone +50 ==="
drive_param perspectiveVertical 50
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-geometry-vertical-50.png" --socket "$SOCKET" >/dev/null

echo "=== horizontal keystone -25 ==="
drive_param perspectiveHorizontal -25
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-geometry-horizontal-neg25.png" --socket "$SOCKET" >/dev/null

echo "=== fine rotation +5 ==="
drive_param perspectiveRotation 5
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-geometry-rotation-5.png" --socket "$SOCKET" >/dev/null

echo "=== chromatic aberration on ==="
drive_flag chromaticAberration true

echo "=== lens vignette on ==="
drive_flag lensVignette true
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-geometry-flags-on.png" --socket "$SOCKET" >/dev/null

echo "=== reset chromatic aberration ==="
"$CLI_BIN" reset-edit-flag "$ASSET_ID" chromaticAberration --socket "$SOCKET" >/dev/null
sleep 1
RESET_OUT=$("$CLI_BIN" get-edit "$ASSET_ID" --socket "$SOCKET")
CA_AFTER=$(printf '%s' "$RESET_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.chromaticAberration')
if [ "$CA_AFTER" != "false" ]; then
    echo "ERROR: reset-edit-flag did not clear chromaticAberration; got '$CA_AFTER'"
    exit 1
fi
echo "  OK: chromaticAberration reset to false"

echo "=== reset all geometry ==="
drive_param perspectiveVertical 0
drive_param perspectiveHorizontal 0
drive_param perspectiveRotation 0
drive_flag lensVignette false

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness develop-geometry flow PASSED ==="
