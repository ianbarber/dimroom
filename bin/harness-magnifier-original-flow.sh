#!/usr/bin/env bash
# harness-magnifier-original-flow.sh — Layer C flow proving the Develop pixel
# magnifier swaps its source to the FULL-RESOLUTION original (#396, follow-up
# to #324/#376/#395).
#
# The sibling harness-magnifier-flow.sh only ever exercises the preview
# fallback: the fixture has no Drive originals, so the magnifier stays on the
# "Lower resolution" preview and `magnifier.usingPreviewFallback` is always
# true. This flow seeds a Drive-backed asset and injects the
# `quadrant-original` stub downloader (which, unlike slow-chunks /
# hold-until-released, writes a REAL decodable JPEG), so the magnifier's async
# source-swap actually fires. It then polls `state` until
# `data.magnifier.usingPreviewFallback` flips to false — the end-to-end proof
# that the full-res original path runs through the real app — and screenshots
# the four-quadrant patch at the centre sample point.
#
# Not wired into bin/harness-smoke.sh / CI yet (kept out of scope to keep the
# PR small, like harness-download-flow.sh). Run locally with:
#   bin/harness-magnifier-original-flow.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/magnifier-original}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-magnifier-original"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-magnifier-original-$$.sock"
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

echo "=== Seeding catalog (with --drive-backed) from $SEED_SRC ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$ORIGINALS_CACHE"
"$FIXTURE_BIN" seed \
    --catalog "$CATALOG_PATH" \
    --cache "$PREVIEW_CACHE" \
    --seed-dir "$SEED_SRC" \
    --drive-backed

if [ ! -f "$CATALOG_PATH" ]; then
    echo "ERROR: dimroom-fixture did not produce $CATALOG_PATH"
    exit 1
fi

echo "=== Launching app in harness mode (quadrant-original stub downloader) ==="
# The stub writes a real 4-quadrant JPEG, so decodeOriginal succeeds and the
# magnifier's source-swap clears the preview-fallback badge. Originals are
# scoped to $WORK_DIR/originals by the launch helper (HARNESS_WORK_DIR).
FIXTURE_CATALOG="$CATALOG_PATH"
HARNESS_WORK_DIR="$WORK_DIR"
HARNESS_ENV=(
    DIMROOM_HARNESS_DISABLE_DRIVE=1
    DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0
    DIMROOM_HARNESS_STUB_DOWNLOADER=quadrant-original
    DIMROOM_ORIGINALS_CACHE_BYTES=1048576
)
harness_launch_app

mkdir -p "$SCREENSHOT_DIR"

echo "=== navigate library ==="
NAV_OUT=$("$CLI_BIN" navigate library --socket "$SOCKET")
if ! echo "$NAV_OUT" | grep -q '"ok"'; then
    echo "ERROR: navigate library did not return ok: $NAV_OUT"
    exit 1
fi

echo "=== list-assets — find the Drive-only asset ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
# The seeder names the Drive-backed fixture row "drive-backed.jpg". Match on
# filename to grab its id without depending on grid sort order.
ASSET_ID=$(paste \
    <(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[*].id') \
    <(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[*].originalFilename') \
    | awk -F'\t' '$2 == "drive-backed.jpg" { print $1; exit }')
if [ -z "$ASSET_ID" ]; then
    echo "ERROR: failed to find Drive-only fixture row in list-assets"
    echo "  list-assets: $LIST_OUT"
    exit 1
fi
echo "  Drive-only asset id: $ASSET_ID"

echo "=== select-asset + navigate develop ==="
"$CLI_BIN" select-asset "$ASSET_ID" --socket "$SOCKET" >/dev/null
"$CLI_BIN" navigate develop --socket "$SOCKET" >/dev/null
# Let the develop view load its preview source before showing the magnifier —
# loadMagnifierSourceIfNeeded needs a preview in hand to seed the window.
sleep 1

echo "=== set-magnifier --visible true --x 0.5 --y 0.5 --zoom 2 ==="
# Showing the magnifier (a not-visible → visible transition) is what triggers
# loadMagnifierSourceIfNeeded, which kicks off the async original fetch+decode.
SM_OUT=$("$CLI_BIN" set-magnifier --visible true --x 0.5 --y 0.5 --zoom 2 --socket "$SOCKET")
if ! echo "$SM_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-magnifier did not return ok: $SM_OUT"
    exit 1
fi

echo "=== Poll state until the full-res original swaps in (badge clears) ==="
# The swap happens on magnifierSourceTask AFTER set-magnifier returns: the stub
# download + decode is near-instant but still off the command's return, so poll
# rather than read once. Up to 5 s at 50 ms intervals.
SWAP_HIT=""
STATE_OUT=""
for i in $(seq 1 100); do
    STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
    FALLBACK=$(printf '%s' "$STATE_OUT" \
        | "$REPO_ROOT/bin/harness-json-extract" 'data.magnifier.usingPreviewFallback' \
            --default 'true')
    if [ "$FALLBACK" = "false" ]; then
        SWAP_HIT="yes"
        echo "  Full-res original swapped in after ${i} polls (usingPreviewFallback=false)"
        break
    fi
    sleep 0.05
done
if [ -z "$SWAP_HIT" ]; then
    echo "ERROR: magnifier never left the preview fallback (usingPreviewFallback stayed true)"
    echo "  Last state: $STATE_OUT"
    exit 1
fi

echo "=== Assert magnifier still visible at 2:1 on the sampled point ==="
VISIBLE=$(printf '%s' "$STATE_OUT" \
    | "$REPO_ROOT/bin/harness-json-extract" 'data.magnifier.visible' --default 'false')
ZOOM=$(printf '%s' "$STATE_OUT" \
    | "$REPO_ROOT/bin/harness-json-extract" 'data.magnifier.zoom' --default '0')
if [ "$VISIBLE" != "true" ]; then
    echo "ERROR: expected magnifier.visible == true, got '$VISIBLE'"
    exit 1
fi
if [ "$ZOOM" != "2" ]; then
    echo "ERROR: expected magnifier.zoom == 2, got '$ZOOM'"
    exit 1
fi
echo "  OK: visible=$VISIBLE zoom=$ZOOM"

echo "=== screenshot: magnifier on full-res original at centre ==="
SHOT_PATH="$SCREENSHOT_DIR/magnifier-original-fullres.png"
SHOT_OUT=$("$CLI_BIN" screenshot "$SHOT_PATH" --socket "$SOCKET")
if ! echo "$SHOT_OUT" | grep -q '"ok"'; then
    echo "ERROR: screenshot command did not return ok: $SHOT_OUT"
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

echo "=== Harness magnifier original flow PASSED ==="
