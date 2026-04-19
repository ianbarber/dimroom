#!/usr/bin/env bash
# harness-develop-ranges-flow.sh — Layer C flow exercising each slider at its
# extremes, to verify the #127 range remap is wired end-to-end and to capture
# screenshots that humans can eyeball for dead-zones.
#
# For each parameter: drive it to +100 (or a high usable value), screenshot,
# back to 0, drive to -100 (or low), screenshot, back to 0. get-edit after
# each step pins that the value landed.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set
# by the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/develop-ranges}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-develop-ranges"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-develop-ranges-$$.sock"
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

# drive <parameter> <value> — set the parameter, wait for debounced render,
# then assert get-edit reports the value.
drive() {
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
    # Harness returns Doubles; strip trailing .0 for exact integer compare when possible.
    local actual_f expected_f
    actual_f=$(/usr/bin/python3 -c "import sys; print(float(sys.argv[1]))" "$actual")
    expected_f=$(/usr/bin/python3 -c "import sys; print(float(sys.argv[1]))" "$value")
    if [ "$actual_f" != "$expected_f" ]; then
        echo "ERROR: expected $param == $expected_f, got '$actual_f'"
        exit 1
    fi
    echo "  OK: $param == $actual_f"
}

# Each slider: drive to max, screenshot, back to 0, drive to min, screenshot.
# Temperature and tint live at neutral 6500/0 and use different extremes.
for param in exposure contrast highlights shadows whites blacks clarity vibrance saturation; do
    echo "=== $param: +100 ==="
    # Exposure is in EV stops — ±5, not ±100.
    if [ "$param" = "exposure" ]; then
        MAX=5
        MIN=-5
    else
        MAX=100
        MIN=-100
    fi

    drive "$param" "$MAX"
    "$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-${param}-max.png" --socket "$SOCKET" >/dev/null
    if [ ! -f "$SCREENSHOT_DIR/develop-${param}-max.png" ]; then
        echo "ERROR: max screenshot not created for $param"
        exit 1
    fi

    echo "=== $param: 0 (reset between extremes) ==="
    drive "$param" 0

    echo "=== $param: -100 ==="
    drive "$param" "$MIN"
    "$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-${param}-min.png" --socket "$SOCKET" >/dev/null
    if [ ! -f "$SCREENSHOT_DIR/develop-${param}-min.png" ]; then
        echo "ERROR: min screenshot not created for $param"
        exit 1
    fi

    echo "=== $param: 0 (reset after sweep) ==="
    drive "$param" 0
done

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness develop-ranges flow PASSED ==="
