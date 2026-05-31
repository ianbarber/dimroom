#!/usr/bin/env bash
# harness-magnifier-offset-flow.sh — Layer C flow for the magnifier window
# off-screen clamp (#377).
#
# Seeds a throwaway catalog, launches the app in harness mode, picks an
# asset, enters Develop, shows the magnifier, then drives
# `set-magnifier-offset` to verify the floating window's drag offset is
# clamped so the whole window stays on-screen:
#   - an in-bounds offset is preserved verbatim,
#   - a huge positive offset (toward / past the bottom-right) is pinned at
#     the anchor horizontally and bounded vertically,
#   - a huge negative offset (toward / past the top-left) is pinned at the
#     anchor vertically and bounded horizontally.
# Screenshots show the window remains visible at each step.
#
# The actual move is a pointer drag the harness can't synthesise (see #348),
# so the command sets the offset directly through the same clamping path the
# drag gesture uses.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set by
# the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/magnifier-offset}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-magnifier-offset"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-magnifier-offset-$$.sock"
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

# Extract a numeric field from a `state` response's data.magnifier block.
magnifier_field() {
    printf '%s' "$1" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(doc['data']['magnifier']['$2'])
"
}

# Assert a python boolean expression over a value, exiting non-zero on fail.
# Usage: assert_num <value> <expr-using-v> <message>
assert_num() {
    local v="$1" expr="$2" msg="$3"
    local ok
    ok=$(/usr/bin/python3 -c "v=float('$v'); print('ok' if ($expr) else 'no')")
    if [ "$ok" != "ok" ]; then
        echo "ERROR: $msg (got $v)"
        exit 1
    fi
}

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

echo "=== select-asset + navigate develop ==="
"$CLI_BIN" select-asset "$ASSET_ID" --socket "$SOCKET" >/dev/null
"$CLI_BIN" navigate develop --socket "$SOCKET" >/dev/null
sleep 1

echo "=== show magnifier so the window lays out (geometry reader reports size) ==="
"$CLI_BIN" set-magnifier --visible true --x 0.5 --y 0.5 --zoom 2 --socket "$SOCKET" >/dev/null
sleep 1

echo "=== set-magnifier-offset --x -50 --y 30 (in-bounds, preserved verbatim) ==="
"$CLI_BIN" set-magnifier-offset --x -50 --y 30 --socket "$SOCKET" >/dev/null
sleep 1
STATE=$("$CLI_BIN" state --socket "$SOCKET")
OFF_X=$(magnifier_field "$STATE" windowOffsetX)
OFF_Y=$(magnifier_field "$STATE" windowOffsetY)
assert_num "$OFF_X" "abs(v - (-50)) < 1e-6" "in-bounds windowOffsetX should be preserved at -50"
assert_num "$OFF_Y" "abs(v - 30) < 1e-6" "in-bounds windowOffsetY should be preserved at 30"
echo "  OK: in-bounds offset preserved ($OFF_X, $OFF_Y)"
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/magnifier-offset-inbounds.png" --socket "$SOCKET" >/dev/null

echo "=== set-magnifier-offset --x 100000 --y 100000 (off bottom-right → clamped) ==="
"$CLI_BIN" set-magnifier-offset --x 100000 --y 100000 --socket "$SOCKET" >/dev/null
sleep 1
STATE=$("$CLI_BIN" state --socket "$SOCKET")
OFF_X=$(magnifier_field "$STATE" windowOffsetX)
OFF_Y=$(magnifier_field "$STATE" windowOffsetY)
# Rightward travel is pinned at the anchor (0); downward travel is bounded
# well below the raw 100000 request.
assert_num "$OFF_X" "abs(v) < 1e-6" "rightward windowOffsetX should pin to 0"
assert_num "$OFF_Y" "v >= 0 and v < 100000" "downward windowOffsetY should be clamped into bounds"
echo "  OK: clamped to anchor-right, bounded-down ($OFF_X, $OFF_Y)"
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/magnifier-offset-clamped-br.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/magnifier-offset-clamped-br.png" ]; then
    echo "ERROR: clamped (bottom-right) screenshot not created"
    exit 1
fi

echo "=== set-magnifier-offset --x -100000 --y -100000 (off top-left → clamped) ==="
"$CLI_BIN" set-magnifier-offset --x -100000 --y -100000 --socket "$SOCKET" >/dev/null
sleep 1
STATE=$("$CLI_BIN" state --socket "$SOCKET")
OFF_X=$(magnifier_field "$STATE" windowOffsetX)
OFF_Y=$(magnifier_field "$STATE" windowOffsetY)
# Upward travel is pinned at the anchor (0); leftward travel is bounded well
# above the raw -100000 request (and never positive).
assert_num "$OFF_Y" "abs(v) < 1e-6" "upward windowOffsetY should pin to 0"
assert_num "$OFF_X" "v <= 0 and v > -100000" "leftward windowOffsetX should be clamped into bounds"
echo "  OK: clamped to anchor-top, bounded-left ($OFF_X, $OFF_Y)"
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/magnifier-offset-clamped-tl.png" --socket "$SOCKET" >/dev/null

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness magnifier offset flow PASSED ==="
