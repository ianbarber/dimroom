#!/usr/bin/env bash
# harness-navigation-flow.sh — Layer C flow for selectNext / selectPrevious.
#
# Seeds a 3-asset catalog, selects the first asset, walks forward with
# selectNext (asserting selectedAssetId changes via state at each step),
# confirms no-wrap at the last row, then walks backward with selectPrevious
# with the same state assertions, and confirms no-wrap at the first row.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set
# by the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/navigation}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-navigation"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-navigation-$$.sock"
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

# Helper: extract selectedAssetId from state output
get_selected_id() {
    local state_out
    state_out=$("$CLI_BIN" state --socket "$SOCKET")
    printf '%s' "$state_out" | "$REPO_ROOT/bin/harness-json-extract" 'data.selectedAssetId' --default ''
}

echo "=== navigate library ==="
NAV_OUT=$("$CLI_BIN" navigate library --socket "$SOCKET")
echo "$NAV_OUT"
if ! echo "$NAV_OUT" | grep -q '"ok"'; then
    echo "ERROR: navigate library did not return ok"
    exit 1
fi

echo "=== list-assets — collect all asset ids ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"
ASSET_IDS=()
while IFS= read -r line; do
    ASSET_IDS+=("$line")
done < <(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[*].id')
ASSET_COUNT=${#ASSET_IDS[@]}
echo "  Found $ASSET_COUNT assets"
if [ "$ASSET_COUNT" -lt 3 ]; then
    echo "ERROR: expected at least 3 assets, got $ASSET_COUNT"
    exit 1
fi

# Regression guard: list-assets must return rows in grid order
# (captureDate desc). The seed fixture assigns the newest capture date to
# 03.jpg, so it must come first. Catches accidental reverts of the sort
# that would silently re-break selectNext navigation (see #118).
FIRST_FILENAME=$(printf '%s' "$LIST_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(doc['data'][0]['originalFilename'])
")
if [ "$FIRST_FILENAME" != "03.jpg" ]; then
    echo "ERROR: expected first list-assets row to be 03.jpg (newest captureDate), got '$FIRST_FILENAME'"
    exit 1
fi
echo "  OK: first row is 03.jpg (grid order preserved)"

echo "=== select first asset ==="
SEL_OUT=$("$CLI_BIN" select-asset "${ASSET_IDS[0]}" --socket "$SOCKET")
echo "$SEL_OUT"
if ! echo "$SEL_OUT" | grep -q '"ok"'; then
    echo "ERROR: select-asset did not return ok"
    exit 1
fi
CURRENT=$(get_selected_id)
if [ "$CURRENT" != "${ASSET_IDS[0]}" ]; then
    echo "ERROR: expected selectedAssetId == ${ASSET_IDS[0]}, got '$CURRENT'"
    exit 1
fi
echo "  OK: selectedAssetId == ${ASSET_IDS[0]}"

# --- Forward navigation with selectNext ---

echo "=== selectNext: first -> second ==="
NEXT_OUT=$("$CLI_BIN" select-next --socket "$SOCKET")
echo "$NEXT_OUT"
if ! echo "$NEXT_OUT" | grep -q '"ok"'; then
    echo "ERROR: select-next did not return ok"
    exit 1
fi
CURRENT=$(get_selected_id)
if [ "$CURRENT" != "${ASSET_IDS[1]}" ]; then
    echo "ERROR: expected selectedAssetId == ${ASSET_IDS[1]}, got '$CURRENT'"
    exit 1
fi
echo "  OK: selectedAssetId == ${ASSET_IDS[1]}"

echo "=== selectNext: second -> third ==="
NEXT_OUT=$("$CLI_BIN" select-next --socket "$SOCKET")
echo "$NEXT_OUT"
if ! echo "$NEXT_OUT" | grep -q '"ok"'; then
    echo "ERROR: select-next did not return ok"
    exit 1
fi
CURRENT=$(get_selected_id)
if [ "$CURRENT" != "${ASSET_IDS[2]}" ]; then
    echo "ERROR: expected selectedAssetId == ${ASSET_IDS[2]}, got '$CURRENT'"
    exit 1
fi
echo "  OK: selectedAssetId == ${ASSET_IDS[2]}"

echo "=== selectNext at end: should stay on third (no wrap) ==="
NEXT_OUT=$("$CLI_BIN" select-next --socket "$SOCKET")
echo "$NEXT_OUT"
if ! echo "$NEXT_OUT" | grep -q '"ok"'; then
    echo "ERROR: select-next did not return ok"
    exit 1
fi
CURRENT=$(get_selected_id)
if [ "$CURRENT" != "${ASSET_IDS[2]}" ]; then
    echo "ERROR: expected selectedAssetId to stay ${ASSET_IDS[2]}, got '$CURRENT'"
    exit 1
fi
echo "  OK: no wrap — still on ${ASSET_IDS[2]}"

# --- Backward navigation with selectPrevious ---

echo "=== selectPrevious: third -> second ==="
PREV_OUT=$("$CLI_BIN" select-previous --socket "$SOCKET")
echo "$PREV_OUT"
if ! echo "$PREV_OUT" | grep -q '"ok"'; then
    echo "ERROR: select-previous did not return ok"
    exit 1
fi
CURRENT=$(get_selected_id)
if [ "$CURRENT" != "${ASSET_IDS[1]}" ]; then
    echo "ERROR: expected selectedAssetId == ${ASSET_IDS[1]}, got '$CURRENT'"
    exit 1
fi
echo "  OK: selectedAssetId == ${ASSET_IDS[1]}"

echo "=== selectPrevious: second -> first ==="
PREV_OUT=$("$CLI_BIN" select-previous --socket "$SOCKET")
echo "$PREV_OUT"
if ! echo "$PREV_OUT" | grep -q '"ok"'; then
    echo "ERROR: select-previous did not return ok"
    exit 1
fi
CURRENT=$(get_selected_id)
if [ "$CURRENT" != "${ASSET_IDS[0]}" ]; then
    echo "ERROR: expected selectedAssetId == ${ASSET_IDS[0]}, got '$CURRENT'"
    exit 1
fi
echo "  OK: selectedAssetId == ${ASSET_IDS[0]}"

echo "=== selectPrevious at start: should stay on first (no wrap) ==="
PREV_OUT=$("$CLI_BIN" select-previous --socket "$SOCKET")
echo "$PREV_OUT"
if ! echo "$PREV_OUT" | grep -q '"ok"'; then
    echo "ERROR: select-previous did not return ok"
    exit 1
fi
CURRENT=$(get_selected_id)
if [ "$CURRENT" != "${ASSET_IDS[0]}" ]; then
    echo "ERROR: expected selectedAssetId to stay ${ASSET_IDS[0]}, got '$CURRENT'"
    exit 1
fi
echo "  OK: no wrap — still on ${ASSET_IDS[0]}"

# --- Screenshot for PR ---

sleep 1
echo "=== screenshot ==="
mkdir -p "$SCREENSHOT_DIR"
SHOT_PATH="$SCREENSHOT_DIR/navigation.png"
SHOT_OUT=$("$CLI_BIN" screenshot "$SHOT_PATH" --socket "$SOCKET")
echo "$SHOT_OUT"
if ! echo "$SHOT_OUT" | grep -q '"ok"'; then
    echo "ERROR: screenshot command did not return ok"
    exit 1
fi
if [ ! -f "$SHOT_PATH" ]; then
    echo "ERROR: screenshot file not created at $SHOT_PATH"
    exit 1
fi
FILE_TYPE=$(file -b "$SHOT_PATH")
if ! echo "$FILE_TYPE" | grep -qi "png"; then
    echo "ERROR: screenshot is not a valid PNG: $FILE_TYPE"
    exit 1
fi
echo "Screenshot verified: $FILE_TYPE"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness navigation flow PASSED ==="
