#!/usr/bin/env bash
# harness-develop-hsl-flow.sh — Layer C flow exercising the HSL panel.
#
# For each axis (hueShift, hslSaturation, hslLuminance) and each of the
# eight bands (0..7 = red, orange, yellow, green, aqua, blue, purple,
# magenta): drive the band to +100, screenshot, reset, drive to -100,
# screenshot, reset. Verifies each value lands via get-edit on the
# matching array element.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set
# by the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/develop-hsl}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-develop-hsl"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
# Scope the originals staging dir + LRU originals cache under $WORK_DIR so
# any originals fetch writes its downloads + index.json here, never into the
# user's real ~/Library/Application Support/Dimroom/originals (issue #331).
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-develop-hsl-$$.sock"
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

# assert_array <parameter> <index> <expected> — read the array slot via
# get-edit and fail unless it equals expected. parameter is one of
# hueShift, hslSaturation, hslLuminance.
assert_array() {
    local param="$1"
    local index="$2"
    local expected="$3"
    local get_out actual
    get_out=$("$CLI_BIN" get-edit "$ASSET_ID" --socket "$SOCKET")
    actual=$(printf '%s' "$get_out" | "$REPO_ROOT/bin/harness-json-extract" "data.$param[$index]")
    local actual_f expected_f
    actual_f=$(/usr/bin/python3 -c "import sys; print(float(sys.argv[1]))" "$actual")
    expected_f=$(/usr/bin/python3 -c "import sys; print(float(sys.argv[1]))" "$expected")
    if [ "$actual_f" != "$expected_f" ]; then
        echo "ERROR: expected $param[$index] == $expected_f, got '$actual_f'"
        exit 1
    fi
    echo "  OK: $param[$index] == $actual_f"
}

# drive_array <parameter> <index> <value> — set the array slot, wait for
# debounced render, then assert get-edit reports the value at that
# index. parameter is one of hueShift, hslSaturation, hslLuminance.
drive_array() {
    local param="$1"
    local index="$2"
    local value="$3"
    local set_out
    # --socket must precede the positional value or a negative value is
    # parsed as a short flag by ArgumentParser.
    set_out=$("$CLI_BIN" set-edit-array-parameter "$ASSET_ID" "$param" "$index" --socket "$SOCKET" -- "$value")
    if ! echo "$set_out" | grep -q '"ok"'; then
        echo "ERROR: set-edit-array-parameter $param[$index]=$value did not return ok"
        echo "$set_out"
        exit 1
    fi
    sleep 1
    assert_array "$param" "$index" "$value"
}

# Each axis × each band: drive to +100, screenshot, reset, drive to -100,
# screenshot, reset. Eight bands × three axes = 24 sweeps.
BANDS=(red orange yellow green aqua blue purple magenta)

for axis in hueShift hslSaturation hslLuminance; do
    for index in 0 1 2 3 4 5 6 7; do
        band="${BANDS[$index]}"

        echo "=== $axis[$index]=$band : +100 ==="
        drive_array "$axis" "$index" 100
        "$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-hsl-${axis}-${band}-max.png" --socket "$SOCKET" >/dev/null
        if [ ! -f "$SCREENSHOT_DIR/develop-hsl-${axis}-${band}-max.png" ]; then
            echo "ERROR: max screenshot not created for $axis[$index]=$band"
            exit 1
        fi

        echo "=== $axis[$index]=$band : 0 ==="
        "$CLI_BIN" reset-edit-array-parameter "$ASSET_ID" "$axis" "$index" --socket "$SOCKET" >/dev/null
        sleep 1
        assert_array "$axis" "$index" 0

        echo "=== $axis[$index]=$band : -100 ==="
        drive_array "$axis" "$index" -100
        "$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-hsl-${axis}-${band}-min.png" --socket "$SOCKET" >/dev/null
        if [ ! -f "$SCREENSHOT_DIR/develop-hsl-${axis}-${band}-min.png" ]; then
            echo "ERROR: min screenshot not created for $axis[$index]=$band"
            exit 1
        fi

        echo "=== $axis[$index]=$band : 0 (reset) ==="
        "$CLI_BIN" reset-edit-array-parameter "$ASSET_ID" "$axis" "$index" --socket "$SOCKET" >/dev/null
        sleep 1
        assert_array "$axis" "$index" 0
    done
done

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness develop-hsl flow PASSED ==="
