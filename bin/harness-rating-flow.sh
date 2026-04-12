#!/usr/bin/env bash
# harness-rating-flow.sh — Layer C flow for Stage 2.3 culling.
#
# Boots the app in harness mode against a fresh catalog, imports the
# three fixture JPEGs, rates two of them 5 stars, applies a min-rating
# filter of 3, takes a filtered screenshot, asserts list-assets now
# returns only the rated rows, rotates one of them, then takes a
# rotated screenshot. This is the end-to-end check that the harness
# surface can drive the full rating/rotate/filter workflow that makes
# Stage 1+2 a shippable culling slice.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set
# by the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/rating}"
IMPORT_SOURCE="$REPO_ROOT/fixtures/import"
WORK_DIR="$REPO_ROOT/.artifacts/harness-rating"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
ORIGINALS_DIR="$WORK_DIR/originals"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-rating-$$.sock"
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

for bin in "$APP_BIN" "$CLI_BIN"; do
    if [ ! -x "$bin" ]; then
        echo "ERROR: missing binary $bin — capture-screenshots skill should have built it"
        exit 1
    fi
done

echo "=== Preparing working catalog ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$ORIGINALS_DIR" "$PREVIEW_CACHE"
# CatalogDatabase(path:) will open or create the file and run migrations.
rm -f "$CATALOG_PATH"

echo "=== Launching app in harness mode ==="
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_ORIGINALS_DIR="$ORIGINALS_DIR" \
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

echo "=== import-folder $IMPORT_SOURCE (expect 3 imported) ==="
IMPORT_OUT=$("$CLI_BIN" import-folder "$IMPORT_SOURCE" --socket "$SOCKET")
echo "$IMPORT_OUT"
IMPORTED=$(printf '%s' "$IMPORT_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(doc['data']['importedCount'])
")
if [ "$IMPORTED" != "3" ]; then
    echo "ERROR: expected importedCount == 3, got '$IMPORTED'"
    exit 1
fi

echo "=== list-assets — capture three ids ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"
# macOS ships with bash 3.2 so `mapfile` is unavailable; read the ids
# via newline-separated output instead and verify the count by hand.
IDS_RAW=$(printf '%s' "$LIST_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
for row in doc['data']:
    print(row['id'])
")
ID1=$(echo "$IDS_RAW" | sed -n '1p')
ID2=$(echo "$IDS_RAW" | sed -n '2p')
ID3=$(echo "$IDS_RAW" | sed -n '3p')
if [ -z "$ID1" ] || [ -z "$ID2" ] || [ -z "$ID3" ]; then
    echo "ERROR: expected 3 asset ids, got: $IDS_RAW"
    exit 1
fi
echo "  ids: $ID1 $ID2 $ID3"

echo "=== set-rating $ID1 5 ==="
"$CLI_BIN" set-rating "$ID1" 5 --socket "$SOCKET" | head -3

echo "=== set-rating $ID2 5 (leaves $ID3 at 0) ==="
"$CLI_BIN" set-rating "$ID2" 5 --socket "$SOCKET" | head -3

echo "=== set-filter 3 ==="
"$CLI_BIN" set-filter 3 --socket "$SOCKET" | head -3

echo "=== navigate library ==="
"$CLI_BIN" navigate library --socket "$SOCKET" | head -3

# SwiftUI needs a tick after the filter change to redraw.
sleep 1

echo "=== screenshot filtered ==="
mkdir -p "$SCREENSHOT_DIR"
FILTERED_SHOT="$SCREENSHOT_DIR/filtered.png"
"$CLI_BIN" screenshot "$FILTERED_SHOT" --socket "$SOCKET" | head -3
if [ ! -f "$FILTERED_SHOT" ]; then
    echo "ERROR: filtered screenshot not created at $FILTERED_SHOT"
    exit 1
fi
FILE_TYPE=$(file -b "$FILTERED_SHOT")
if ! echo "$FILE_TYPE" | grep -qi "png"; then
    echo "ERROR: filtered screenshot is not a valid PNG: $FILE_TYPE"
    exit 1
fi

echo "=== list-assets (expect 2 rows, both with rating >= 3) ==="
FILTERED_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$FILTERED_OUT"
FILTERED_LEN=$(printf '%s' "$FILTERED_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(len(doc['data']))
")
if [ "$FILTERED_LEN" != "2" ]; then
    echo "ERROR: expected 2 filtered rows, got $FILTERED_LEN"
    exit 1
fi
echo "  OK: filtered list length == 2"

RATINGS_OK=$(printf '%s' "$FILTERED_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(all(row['rating'] >= 3 for row in doc['data']))
")
if [ "$RATINGS_OK" != "True" ]; then
    echo "ERROR: filtered rows contained a rating < 3"
    exit 1
fi
echo "  OK: all filtered rows have rating >= 3"

echo "=== state — assert minRating == 3 ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
MIN_RATING=$(printf '%s' "$STATE_OUT" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
print(doc['data']['minRating'])
")
if [ "$MIN_RATING" != "3" ]; then
    echo "ERROR: expected minRating == 3, got '$MIN_RATING'"
    exit 1
fi
echo "  OK: minRating == 3"

echo "=== rotate $ID1 ==="
"$CLI_BIN" rotate "$ID1" --socket "$SOCKET" | head -3

echo "=== list-assets — confirm $ID1 rotation == 90 ==="
POST_ROTATE=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$POST_ROTATE"
ROTATION=$(printf '%s' "$POST_ROTATE" | /usr/bin/python3 -c "
import json, sys
doc = json.loads(sys.stdin.read())
for row in doc['data']:
    if row['id'] == '$ID1':
        print(row['rotation'])
        break
")
if [ "$ROTATION" != "90" ]; then
    echo "ERROR: expected rotation == 90 for $ID1, got '$ROTATION'"
    exit 1
fi
echo "  OK: rotation == 90"

echo "=== navigate loupe + select $ID1 ==="
"$CLI_BIN" select-asset "$ID1" --socket "$SOCKET" | head -3
"$CLI_BIN" navigate loupe --socket "$SOCKET" | head -3
sleep 1

echo "=== screenshot rotated ==="
ROTATED_SHOT="$SCREENSHOT_DIR/rotated.png"
"$CLI_BIN" screenshot "$ROTATED_SHOT" --socket "$SOCKET" | head -3
if [ ! -f "$ROTATED_SHOT" ]; then
    echo "ERROR: rotated screenshot not created at $ROTATED_SHOT"
    exit 1
fi
FILE_TYPE=$(file -b "$ROTATED_SHOT")
if ! echo "$FILE_TYPE" | grep -qi "png"; then
    echo "ERROR: rotated screenshot is not a valid PNG: $FILE_TYPE"
    exit 1
fi
echo "Rotated screenshot verified: $FILE_TYPE"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness rating flow PASSED ==="
