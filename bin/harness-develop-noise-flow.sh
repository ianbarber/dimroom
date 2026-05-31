#!/usr/bin/env bash
# harness-develop-noise-flow.sh — Layer C flow for the new Noise Reduction
# group in Develop.
#
# Seeds a throwaway catalog, launches the app in harness mode, enters Develop
# on the first asset and drives the luminance + chrominance sliders to a few
# meaningful states, asserting get-edit round-trips each value and capturing
# screenshots for human review.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set by
# the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/develop-noise}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-develop-noise"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
# Scope the originals staging dir + LRU originals cache under $WORK_DIR so
# any originals fetch writes its downloads + index.json here, never into the
# user's real ~/Library/Application Support/Dimroom/originals (issue #331).
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-develop-noise-$$.sock"
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
HARNESS_ENV=(DIMROOM_HARNESS_DISABLE_DRIVE=1 DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0)
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

# drive <parameter> <value> — set the parameter, wait for debounced render,
# then assert get-edit reports the value.
drive() {
    local param="$1"
    local value="$2"
    local set_out
    set_out=$("$CLI_BIN" set-edit-parameter "$ASSET_ID" "$param" "$value" --socket "$SOCKET")
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

echo "=== luminance NR only @ 80 ==="
drive luminanceNoiseReduction 80
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-noise-luma-80.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/develop-noise-luma-80.png" ]; then
    echo "ERROR: luma screenshot not created"
    exit 1
fi

echo "=== reset luminance NR ==="
drive luminanceNoiseReduction 0

echo "=== chrominance NR only @ 80 ==="
drive chrominanceNoiseReduction 80
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-noise-chroma-80.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/develop-noise-chroma-80.png" ]; then
    echo "ERROR: chroma screenshot not created"
    exit 1
fi

echo "=== both NR sliders @ 100 ==="
drive luminanceNoiseReduction 100
drive chrominanceNoiseReduction 100
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-noise-both-100.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/develop-noise-both-100.png" ]; then
    echo "ERROR: combined screenshot not created"
    exit 1
fi

echo "=== reset both NR sliders ==="
drive luminanceNoiseReduction 0
drive chrominanceNoiseReduction 0

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness develop-noise flow PASSED ==="
