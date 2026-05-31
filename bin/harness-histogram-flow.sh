#!/usr/bin/env bash
# harness-histogram-flow.sh — Layer C flow for the Develop histogram toggle.
#
# Seeds a throwaway catalog, launches the app in harness mode, selects an
# asset, navigates to develop, and exercises the toggle-histogram command
# while asserting showHistogram state transitions in the AppState response.
#
# Assumes the capture-screenshots skill already built the app, CLI, and
# fixture seeder — this script must not rebuild. SCREENSHOT_DIR is set
# by the capture skill per-flow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/histogram}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-histogram"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
# Scope the originals staging dir + LRU originals cache under $WORK_DIR so
# any originals fetch writes its downloads + index.json here, never into the
# user's real ~/Library/Application Support/Dimroom/originals (issue #331).
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-histogram-$$.sock"
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

take_screenshot() {
    local name="$1"
    local shot_path="$SCREENSHOT_DIR/$name.png"
    echo "=== screenshot: $name ==="
    local shot_out
    shot_out=$("$CLI_BIN" screenshot "$shot_path" --socket "$SOCKET")
    echo "$shot_out"
    if ! echo "$shot_out" | grep -q '"ok"'; then
        echo "ERROR: screenshot command did not return ok"
        exit 1
    fi
    if [ ! -f "$shot_path" ]; then
        echo "ERROR: screenshot file not created at $shot_path"
        exit 1
    fi
    local file_type
    file_type=$(file -b "$shot_path")
    if ! echo "$file_type" | grep -qi "png"; then
        echo "ERROR: screenshot is not a valid PNG: $file_type"
        exit 1
    fi
    echo "  Screenshot verified: $file_type"
}

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

echo "=== navigate library ==="
NAV_OUT=$("$CLI_BIN" navigate library --socket "$SOCKET")
echo "$NAV_OUT"
if ! echo "$NAV_OUT" | grep -q '"ok"'; then
    echo "ERROR: navigate library did not return ok"
    exit 1
fi

echo "=== list-assets — pick first asset id ==="
LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"
ASSET_ID=$(printf '%s' "$LIST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data[0].id')
if [ -z "$ASSET_ID" ]; then
    echo "ERROR: failed to extract asset id from list-assets response"
    exit 1
fi
echo "  Picked asset id: $ASSET_ID"

echo "=== select-asset $ASSET_ID ==="
SEL_OUT=$("$CLI_BIN" select-asset "$ASSET_ID" --socket "$SOCKET")
echo "$SEL_OUT"
if ! echo "$SEL_OUT" | grep -q '"ok"'; then
    echo "ERROR: select-asset did not return ok"
    exit 1
fi

echo "=== navigate develop ==="
DEV_OUT=$("$CLI_BIN" navigate develop --socket "$SOCKET")
echo "$DEV_OUT"
if ! echo "$DEV_OUT" | grep -q '"ok"'; then
    echo "ERROR: navigate develop did not return ok"
    exit 1
fi

# Let SwiftUI settle after route change so the histogram has a chance to render
sleep 2

mkdir -p "$SCREENSHOT_DIR"

echo "=== state — assert showHistogram == true at startup ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
SHOW=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.showHistogram')
if [ "$SHOW" != "true" ]; then
    echo "ERROR: expected showHistogram == true at startup, got '$SHOW'"
    exit 1
fi
echo "  OK: showHistogram == true (initial)"

take_screenshot "histogram-shown"

echo "=== toggle-histogram — hide ==="
TOG_OUT=$("$CLI_BIN" toggle-histogram --socket "$SOCKET")
echo "$TOG_OUT"
if ! echo "$TOG_OUT" | grep -q '"ok"'; then
    echo "ERROR: toggle-histogram did not return ok"
    exit 1
fi

sleep 1

echo "=== state — assert showHistogram == false after toggle ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
SHOW=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.showHistogram')
if [ "$SHOW" != "false" ]; then
    echo "ERROR: expected showHistogram == false after toggle, got '$SHOW'"
    exit 1
fi
echo "  OK: showHistogram == false (after toggle)"

take_screenshot "histogram-hidden"

echo "=== toggle-histogram — show again ==="
TOG_OUT=$("$CLI_BIN" toggle-histogram --socket "$SOCKET")
echo "$TOG_OUT"
if ! echo "$TOG_OUT" | grep -q '"ok"'; then
    echo "ERROR: toggle-histogram (second) did not return ok"
    exit 1
fi

sleep 1

echo "=== state — assert showHistogram == true after second toggle ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
SHOW=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.showHistogram')
if [ "$SHOW" != "true" ]; then
    echo "ERROR: expected showHistogram == true after second toggle, got '$SHOW'"
    exit 1
fi
echo "  OK: showHistogram == true (after second toggle)"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness histogram flow PASSED ==="
