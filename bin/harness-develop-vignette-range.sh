#!/usr/bin/env bash
# harness-develop-vignette-range.sh — Layer C flow stepping vignetteAmount
# through a six-point negative/positive sweep so a reviewer can eyeball the
# darkening / lightening gradient end-to-end. Companion to the Layer A
# monotonicity tests and Layer B mid-strength snapshot landed in PR #264.
#
# For each target value in {-10, -50, -100, +10, +50, +100}: drive
# vignetteAmount via set-edit-parameter, wait for the debounced render,
# assert get-edit reports the value, then screenshot. The slider is reset
# to 0 between the negative and positive sweeps so each screenshot
# captures the absolute effect of the value rather than a delta.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set
# by the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/develop-vignette-range}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-develop-vignette-range"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-develop-vignette-range-$$.sock"
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

# drive <value> — set vignetteAmount, wait for the debounced render, then
# assert get-edit reports the value.
drive() {
    local value="$1"
    local set_out
    # --socket must precede the positional value or a negative value is
    # parsed as a short flag by ArgumentParser.
    set_out=$("$CLI_BIN" set-edit-parameter "$ASSET_ID" vignetteAmount --socket "$SOCKET" -- "$value")
    if ! echo "$set_out" | grep -q '"ok"'; then
        echo "ERROR: set-edit-parameter vignetteAmount $value did not return ok"
        echo "$set_out"
        exit 1
    fi
    sleep 1
    local get_out actual
    get_out=$("$CLI_BIN" get-edit "$ASSET_ID" --socket "$SOCKET")
    actual=$(printf '%s' "$get_out" | "$REPO_ROOT/bin/harness-json-extract" 'data.vignetteAmount')
    local actual_f expected_f
    actual_f=$(/usr/bin/python3 -c "import sys; print(float(sys.argv[1]))" "$actual")
    expected_f=$(/usr/bin/python3 -c "import sys; print(float(sys.argv[1]))" "$value")
    if [ "$actual_f" != "$expected_f" ]; then
        echo "ERROR: expected vignetteAmount == $expected_f, got '$actual_f'"
        exit 1
    fi
    echo "  OK: vignetteAmount == $actual_f"
}

# shoot <value> <label> — drive then screenshot into a stable filename.
shoot() {
    local value="$1"
    local label="$2"
    drive "$value"
    local out="$SCREENSHOT_DIR/develop-vignette-${label}.png"
    "$CLI_BIN" screenshot "$out" --socket "$SOCKET" >/dev/null
    if [ ! -s "$out" ]; then
        echo "ERROR: screenshot not created or empty: $out"
        exit 1
    fi
    echo "  WROTE: $out"
}

echo "=== negative sweep: -10, -50, -100 ==="
shoot -10  neg10
shoot -50  neg50
shoot -100 neg100

echo "=== reset to 0 between sweeps ==="
drive 0

echo "=== positive sweep: +10, +50, +100 ==="
shoot 10  pos10
shoot 50  pos50
shoot 100 pos100

echo "=== reset to 0 ==="
drive 0

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness develop-vignette-range flow PASSED ==="
