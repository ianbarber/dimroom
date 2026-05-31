#!/usr/bin/env bash
# harness-develop-split-tone-flow.sh — Layer C flow for the new Split Toning
# group in Develop.
#
# Seeds a throwaway catalog, launches the app in harness mode, enters Develop
# on the first asset and drives the five split-toning parameters
# (Balance + Highlights{Hue,Sat} + Shadows{Hue,Sat}) through a classic
# orange-teal grade plus balance-shift variants. Each set-edit-parameter is
# round-tripped through get-edit so the harness-layer string surface is
# exercised end-to-end and screenshots land in SCREENSHOT_DIR for human
# review.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set by
# the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/develop-split-tone}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-develop-split-tone"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
# Scope the originals staging dir + LRU originals cache under $WORK_DIR so
# any originals fetch writes its downloads + index.json here, never into the
# user's real ~/Library/Application Support/Dimroom/originals (issue #331).
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-develop-split-tone-$$.sock"
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

# drive <parameter> <value> — set the parameter, wait for debounced render,
# then assert get-edit reports the value. Uses `--` so negative values
# (e.g. splitToneBalance -50) are treated as positionals rather than
# option flags by swift-argument-parser.
drive() {
    local param="$1"
    local value="$2"
    local set_out
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

echo "=== orange-teal grade, balanced ==="
drive splitToneHighlightHue 30
drive splitToneHighlightSaturation 50
drive splitToneShadowHue 210
drive splitToneShadowSaturation 50
drive splitToneBalance 0
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-split-tone-orange-teal.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/develop-split-tone-orange-teal.png" ]; then
    echo "ERROR: orange-teal screenshot not created"
    exit 1
fi

echo "=== balance shift toward highlights ==="
drive splitToneBalance -50
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-split-tone-balance-minus-50.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/develop-split-tone-balance-minus-50.png" ]; then
    echo "ERROR: balance-minus-50 screenshot not created"
    exit 1
fi

echo "=== balance shift toward shadows ==="
drive splitToneBalance 50
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-split-tone-balance-plus-50.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/develop-split-tone-balance-plus-50.png" ]; then
    echo "ERROR: balance-plus-50 screenshot not created"
    exit 1
fi

echo "=== reset all split-tone sliders ==="
drive splitToneHighlightHue 0
drive splitToneHighlightSaturation 0
drive splitToneShadowHue 0
drive splitToneShadowSaturation 0
drive splitToneBalance 0

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness develop-split-tone flow PASSED ==="
