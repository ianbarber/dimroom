#!/usr/bin/env bash
# harness-develop-gesture-reset-flow.sh — Layer C regression flow for the
# Develop slider double-click reset gesture (#265/#347), driven through a
# *synthesised pointer event* rather than the view-model reset shortcut
# (#348).
#
# ⚠️ BLOCKED — DO NOT ENROL IN CI YET. The synthetic pointer event does not
# currently reach SwiftUI's gesture recogniser in the headless harness, so
# the load-bearing "reset to identity" assertion below FAILS. SwiftUI
# ignores programmatic NSEvents, and real CGEvent injection is dropped
# because the unsigned SPM harness binary is not Accessibility-trusted
# (AXIsProcessTrusted() == false). The geometry/registry/command wiring is
# correct and the click point lands on the slider — only event *delivery*
# is blocked. This script is kept as the reference flow / regression target;
# it will pass once event delivery is resolved (see issue #348).
#
# This flow exercises the one thing no other Layer C command can reach:
# the SwiftUI gesture arbitration between
# `highPriorityGesture(TapGesture(count: 2))` and the `Slider`'s built-in
# click-to-position handling. The regular `reset-edit-parameter` command
# calls `DevelopViewModel.resetParameter` directly, so it would pass even
# if the gesture chain were broken. `double-click-slider` posts a genuine
# double-click NSEvent at the slider's track and lets SwiftUI route it.
#
# Sequence:
#   navigate library → list-assets (pick id) → select-asset → navigate develop
#   → set-edit-parameter vignetteAmount -50      (drive OFF identity)
#   → get-edit asserts vignetteAmount == -50      (negative control: the
#     value is genuinely off-identity before the click, so reaching 0 can
#     only be the reset)
#   → double-click-slider vignetteAmount --at-fraction 0.25
#       posts a real double-click at 25% of the track — a NON-identity
#       position (identity 0 sits at the track centre, ~0.5). macOS Slider
#       jumps its value to a click location, so if the reset gesture did
#       NOT fire the value would land near the click position, not 0.
#   → get-edit asserts vignetteAmount == 0        (only the reset gesture
#     firing explains snapping back to identity from a 0.25 click)
#   → screenshot
#
# Pre-#347-fix (simultaneousGesture), the Slider would also process the
# double-click and overwrite the reset, so the final assert would FAIL —
# which is exactly the regression signal this flow exists to catch.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set
# by the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/develop-gesture-reset}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-develop-gesture-reset"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-develop-gesture-reset-$$.sock"
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

# assert_vignette <expected> — read get-edit and assert vignetteAmount
# equals <expected> (float compare).
assert_vignette() {
    local expected="$1"
    local get_out actual actual_f expected_f
    get_out=$("$CLI_BIN" get-edit "$ASSET_ID" --socket "$SOCKET")
    actual=$(printf '%s' "$get_out" | "$REPO_ROOT/bin/harness-json-extract" 'data.vignetteAmount')
    actual_f=$(/usr/bin/python3 -c "import sys; print(float(sys.argv[1]))" "$actual")
    expected_f=$(/usr/bin/python3 -c "import sys; print(float(sys.argv[1]))" "$expected")
    if [ "$actual_f" != "$expected_f" ]; then
        echo "ERROR: expected vignetteAmount == $expected_f, got '$actual_f'"
        exit 1
    fi
    echo "  OK: vignetteAmount == $actual_f"
}

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

echo "=== drive vignetteAmount OFF identity to -80 ==="
# -80 is chosen distinct from the 0.25 click position (≈ -50 on the value
# axis) so the three outcomes are all distinguishable: reset gesture → 0,
# Slider click-to-position only → ≈ -50, event missed entirely → -80.
# --socket must precede the positional value or the negative value is
# parsed as a short flag by ArgumentParser.
SET_OUT=$("$CLI_BIN" set-edit-parameter "$ASSET_ID" vignetteAmount --socket "$SOCKET" -- -80)
if ! echo "$SET_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-edit-parameter vignetteAmount -80 did not return ok"
    echo "$SET_OUT"
    exit 1
fi
sleep 1

echo "=== negative control: confirm value is off-identity before the click ==="
assert_vignette -80

echo "=== screenshot: off-identity (pre-double-click) ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-gesture-reset-before.png" --socket "$SOCKET" >/dev/null

echo "=== double-click-slider vignetteAmount at 0.25 (non-identity track position) ==="
DC_OUT=$("$CLI_BIN" double-click-slider vignetteAmount --at-fraction 0.25 --socket "$SOCKET")
if ! echo "$DC_OUT" | grep -q '"ok"'; then
    echo "ERROR: double-click-slider did not return ok"
    echo "$DC_OUT"
    exit 1
fi
echo "$DC_OUT"
sleep 1

echo "=== assert the gesture reset vignetteAmount to identity (0) ==="
# This is the load-bearing assertion. The click landed at 0.25 of the
# track (≈ -50 on the value axis), NOT at identity. The value can only be
# 0 if the double-tap reset gesture fired and won the arbitration against
# the Slider's click-to-position — i.e. the #265/#347 fix is intact.
assert_vignette 0

echo "=== screenshot: post-double-click (reset to identity) ==="
"$CLI_BIN" screenshot "$SCREENSHOT_DIR/develop-gesture-reset-after.png" --socket "$SOCKET" >/dev/null
for img in develop-gesture-reset-before develop-gesture-reset-after; do
    if [ ! -s "$SCREENSHOT_DIR/$img.png" ]; then
        echo "ERROR: screenshot not created or empty: $SCREENSHOT_DIR/$img.png"
        exit 1
    fi
done

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness develop-gesture-reset flow PASSED ==="
