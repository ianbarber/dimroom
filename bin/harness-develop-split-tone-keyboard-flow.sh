#!/usr/bin/env bash
# harness-develop-split-tone-keyboard-flow.sh — Layer C flow for the
# ColorWheelControl keyboard / accessibility path (#305).
#
# Seeds a throwaway catalog, launches the app in harness mode, enters
# Develop on the first asset, and drives the two Split Toning wheels with
# the `nudge-color-wheel` command — the same `ColorWheelKeyboardModel`
# step logic the view's `onKeyPress` handler runs. Synthesising NSEvents
# into the SwiftUI focus system is unreliable in harness mode, so the
# harness drives the shared nudge model directly (see the command's doc
# comment in Command.swift). Each nudge is round-tripped through get-edit
# so the keyboard step math is exercised end-to-end, and the focused
# wheel is screenshotted into SCREENSHOT_DIR for human review.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set by
# the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/develop-split-tone-keyboard}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-develop-split-tone-keyboard"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
# Scope the originals staging dir + LRU originals cache under $WORK_DIR so
# any originals fetch writes its downloads + index.json here, never into the
# user's real ~/Library/Application Support/Dimroom/originals (issue #331).
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-develop-split-tone-keyboard-$$.sock"
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

echo "=== navigate develop ==="
"$CLI_BIN" navigate develop --socket "$SOCKET" >/dev/null
sleep 1

# assert_param <parameter> <expected> — round-trip the live edit state
# through get-edit and fail unless the parameter equals expected.
assert_param() {
    local param="$1"
    local expected="$2"
    local get_out actual actual_f expected_f
    get_out=$("$CLI_BIN" get-edit "$ASSET_ID" --socket "$SOCKET")
    actual=$(printf '%s' "$get_out" | "$REPO_ROOT/bin/harness-json-extract" "data.$param")
    actual_f=$(/usr/bin/python3 -c "import sys; print(float(sys.argv[1]))" "$actual")
    expected_f=$(/usr/bin/python3 -c "import sys; print(float(sys.argv[1]))" "$expected")
    if [ "$actual_f" != "$expected_f" ]; then
        echo "ERROR: expected $param == $expected_f, got '$actual_f'"
        exit 1
    fi
    echo "  OK: $param == $actual_f"
}

# nudge <hueParam> <satParam> <key> [--shift] — send one keyboard nudge
# and require an ok response.
nudge() {
    local hue_param="$1"
    local sat_param="$2"
    local key="$3"
    local shift_flag="${4:-}"
    local out
    if [ -n "$shift_flag" ]; then
        out=$("$CLI_BIN" nudge-color-wheel "$ASSET_ID" "$hue_param" "$sat_param" "$key" "$shift_flag" --socket "$SOCKET")
    else
        out=$("$CLI_BIN" nudge-color-wheel "$ASSET_ID" "$hue_param" "$sat_param" "$key" --socket "$SOCKET")
    fi
    if ! echo "$out" | grep -q '"ok"'; then
        echo "ERROR: nudge-color-wheel $key $shift_flag did not return ok"
        echo "$out"
        exit 1
    fi
}

HL_HUE="splitToneHighlightHue"
HL_SAT="splitToneHighlightSaturation"
SH_HUE="splitToneShadowHue"
SH_SAT="splitToneShadowSaturation"

echo "=== highlights wheel starts at identity ==="
assert_param "$HL_HUE" 0
assert_param "$HL_SAT" 0

echo "=== right arrow x3 nudges highlights hue to 15 ==="
nudge "$HL_HUE" "$HL_SAT" right
nudge "$HL_HUE" "$HL_SAT" right
nudge "$HL_HUE" "$HL_SAT" right
assert_param "$HL_HUE" 15
assert_param "$HL_SAT" 0

echo "=== shift+up x4 nudges highlights saturation to 20 ==="
nudge "$HL_HUE" "$HL_SAT" up --shift
nudge "$HL_HUE" "$HL_SAT" up --shift
nudge "$HL_HUE" "$HL_SAT" up --shift
nudge "$HL_HUE" "$HL_SAT" up --shift
assert_param "$HL_SAT" 20
assert_param "$HL_HUE" 15

sleep 1
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-split-tone-keyboard-highlights.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/develop-split-tone-keyboard-highlights.png" ]; then
    echo "ERROR: highlights screenshot not created"
    exit 1
fi

echo "=== reset returns both highlight axes to identity ==="
nudge "$HL_HUE" "$HL_SAT" reset
assert_param "$HL_HUE" 0
assert_param "$HL_SAT" 0

echo "=== shadows wheel round-trip ==="
nudge "$SH_HUE" "$SH_SAT" right
nudge "$SH_HUE" "$SH_SAT" right
assert_param "$SH_HUE" 10
nudge "$SH_HUE" "$SH_SAT" up --shift
nudge "$SH_HUE" "$SH_SAT" up --shift
nudge "$SH_HUE" "$SH_SAT" up --shift
assert_param "$SH_SAT" 15
nudge "$SH_HUE" "$SH_SAT" reset
assert_param "$SH_HUE" 0
assert_param "$SH_SAT" 0

echo "=== left arrow wraps highlights hue below zero to 355 ==="
nudge "$HL_HUE" "$HL_SAT" left
assert_param "$HL_HUE" 355
nudge "$HL_HUE" "$HL_SAT" reset

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness develop-split-tone-keyboard flow PASSED ==="
