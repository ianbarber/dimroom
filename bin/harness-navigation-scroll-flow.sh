#!/usr/bin/env bash
# harness-navigation-scroll-flow.sh — Layer C flow for auto-scroll on
# arrow-key navigation.
#
# Seeds a catalog with 18 assets (3 JPEGs × 6 duplicates) so the grid
# has enough rows to scroll. Selects the first asset, issues select-down
# repeatedly to push selection off-screen, then screenshots. The screenshot
# is the visual evidence for PR review.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/navigation-scroll}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-navigation-scroll"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-nav-scroll-$$.sock"
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

echo "=== Seeding catalog with duplicates for scroll test ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
"$FIXTURE_BIN" seed \
    --catalog "$CATALOG_PATH" \
    --cache "$PREVIEW_CACHE" \
    --seed-dir "$SEED_SRC" \
    --duplicate 6

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

get_selected_id() {
    local state_out
    state_out=$("$CLI_BIN" state --socket "$SOCKET")
    printf '%s' "$state_out" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(doc['data'].get('selectedAssetId', ''))
"
}

echo "=== navigate library ==="
NAV_OUT=$("$CLI_BIN" navigate library --socket "$SOCKET")
echo "$NAV_OUT"
if ! echo "$NAV_OUT" | grep -q '"ok"'; then
    echo "ERROR: navigate library did not return ok"
    exit 1
fi

echo "=== list-assets ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
ASSET_IDS=()
while IFS= read -r line; do
    ASSET_IDS+=("$line")
done < <(printf '%s' "$LIST_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
for a in doc['data']:
    print(a['id'])
")
ASSET_COUNT=${#ASSET_IDS[@]}
echo "  Found $ASSET_COUNT assets"
if [ "$ASSET_COUNT" -lt 16 ]; then
    echo "ERROR: expected at least 16 assets, got $ASSET_COUNT"
    exit 1
fi

echo "=== select first asset ==="
SEL_OUT=$("$CLI_BIN" select-asset "${ASSET_IDS[0]}" --socket "$SOCKET")
if ! echo "$SEL_OUT" | grep -q '"ok"'; then
    echo "ERROR: select-asset did not return ok"
    exit 1
fi
CURRENT=$(get_selected_id)
if [ "$CURRENT" != "${ASSET_IDS[0]}" ]; then
    echo "ERROR: expected selectedAssetId == ${ASSET_IDS[0]}, got '$CURRENT'"
    exit 1
fi
echo "  OK: selected ${ASSET_IDS[0]}"

echo "=== select-down x5 to push selection off-screen ==="
for step in $(seq 1 5); do
    DOWN_OUT=$("$CLI_BIN" select-down --socket "$SOCKET")
    if ! echo "$DOWN_OUT" | grep -q '"ok"'; then
        echo "ERROR: select-down step $step did not return ok"
        exit 1
    fi
    CURRENT=$(get_selected_id)
    EXPECTED_INDEX=$(( step * 4 ))
    if [ "$EXPECTED_INDEX" -lt "$ASSET_COUNT" ]; then
        if [ "$CURRENT" != "${ASSET_IDS[$EXPECTED_INDEX]}" ]; then
            echo "ERROR: step $step expected ${ASSET_IDS[$EXPECTED_INDEX]}, got '$CURRENT'"
            exit 1
        fi
    fi
    echo "  step $step OK: selectedAssetId == $CURRENT"
done

sleep 1
echo "=== screenshot ==="
mkdir -p "$SCREENSHOT_DIR"
SHOT_PATH="$SCREENSHOT_DIR/scroll.png"
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

echo "=== Harness navigation-scroll flow PASSED ==="
