#!/usr/bin/env bash
# harness-curves-flow.sh — Layer C flow exercising the Curves Develop UI
# end-to-end through the harness `setCurvePoints` / `resetCurve` commands.
#
# Drives a luminance S-curve, then a red lift curve, asserting via
# `get-edit` that the curve arrays round-trip through the catalog. Then
# resets each channel and asserts identity is restored.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set
# by the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/curves}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-curves"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
# Scope the originals staging dir + LRU originals cache under $WORK_DIR so
# any originals fetch writes its downloads + index.json here, never into the
# user's real ~/Library/Application Support/Dimroom/originals (issue #331).
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-curves-$$.sock"
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

# assert_curve_length <channel> <expected-count> — read editState for the
# active asset and assert the named curve array has the expected length.
assert_curve_length() {
    local channel="$1"
    local expected="$2"
    local key
    case "$channel" in
        luminance) key="toneCurvePoints" ;;
        red) key="redCurvePoints" ;;
        green) key="greenCurvePoints" ;;
        blue) key="blueCurvePoints" ;;
        *) echo "ERROR: unknown channel $channel"; exit 1 ;;
    esac
    local get_out
    get_out=$("$CLI_BIN" get-edit "$ASSET_ID" --socket "$SOCKET")
    local actual
    actual=$(printf '%s' "$get_out" | /usr/bin/python3 -c "
import sys, json
state = json.load(sys.stdin)['data']
points = state.get('$key', [])
print(len(points))
")
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: expected $channel curve length $expected, got $actual"
        echo "$get_out"
        exit 1
    fi
    echo "  OK: $channel has $actual points"
}

# assert_curve_identity <channel> — assert the named curve is the identity
# [[0,0],[1,1]] pair.
assert_curve_identity() {
    local channel="$1"
    local key
    case "$channel" in
        luminance) key="toneCurvePoints" ;;
        red) key="redCurvePoints" ;;
        green) key="greenCurvePoints" ;;
        blue) key="blueCurvePoints" ;;
    esac
    local get_out
    get_out=$("$CLI_BIN" get-edit "$ASSET_ID" --socket "$SOCKET")
    local result
    # CGPoint encodes as a 2-element array on Apple platforms, so each
    # entry in the curve is `[x, y]`, not `{"x": …, "y": …}`.
    result=$(printf '%s' "$get_out" | /usr/bin/python3 -c "
import sys, json
state = json.load(sys.stdin)['data']
points = state.get('$key', [])
if len(points) != 2:
    print('non-identity-length')
    sys.exit(0)
p0, p1 = points[0], points[1]
def xy(p):
    if isinstance(p, dict):
        return float(p.get('x', 0)), float(p.get('y', 0))
    return float(p[0]), float(p[1])
x0, y0 = xy(p0)
x1, y1 = xy(p1)
if abs(x0) < 1e-9 and abs(y0) < 1e-9 and abs(x1 - 1) < 1e-9 and abs(y1 - 1) < 1e-9:
    print('identity')
else:
    print('non-identity')
")
    if [ "$result" != "identity" ]; then
        echo "ERROR: expected $channel curve to be identity, got '$result'"
        echo "$get_out"
        exit 1
    fi
    echo "  OK: $channel is identity"
}

echo "=== set-curve-points luminance S-curve ==="
"$CLI_BIN" set-curve-points "$ASSET_ID" luminance "[[0,0],[0.25,0.15],[0.75,0.85],[1,1]]" --socket "$SOCKET" >/dev/null
"$CLI_BIN" select-curve-channel luminance --socket "$SOCKET" >/dev/null
sleep 1
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/curves-luminance-s.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/curves-luminance-s.png" ]; then
    echo "ERROR: luminance screenshot not created"
    exit 1
fi
assert_curve_length luminance 4

echo "=== set-curve-points red lift ==="
"$CLI_BIN" set-curve-points "$ASSET_ID" red "[[0,0.05],[0.5,0.6],[1,1]]" --socket "$SOCKET" >/dev/null
"$CLI_BIN" select-curve-channel red --socket "$SOCKET" >/dev/null
sleep 1
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/curves-red.png" --socket "$SOCKET" >/dev/null
if [ ! -f "$SCREENSHOT_DIR/curves-red.png" ]; then
    echo "ERROR: red screenshot not created"
    exit 1
fi
assert_curve_length red 3

echo "=== reset-curve luminance ==="
"$CLI_BIN" reset-curve "$ASSET_ID" luminance --socket "$SOCKET" >/dev/null
sleep 1
assert_curve_identity luminance
# Red should still be the lift curve from the prior step.
assert_curve_length red 3

echo "=== reset-curve red ==="
"$CLI_BIN" reset-curve "$ASSET_ID" red --socket "$SOCKET" >/dev/null
sleep 1
assert_curve_identity red
assert_curve_identity green
assert_curve_identity blue

"$CLI_BIN" select-curve-channel luminance --socket "$SOCKET" >/dev/null
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/curves-reset.png" --socket "$SOCKET" >/dev/null

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness curves flow PASSED ==="
