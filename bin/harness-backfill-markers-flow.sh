#!/usr/bin/env bash
# harness-backfill-markers-flow.sh — Layer C flow for the legacy-marker
# backfill (#328).
#
# Exercises the one-shot `backfill-drive-markers` command end-to-end
# against a fixture catalog seeded with one already-tagged file and one
# untagged (legacy) file:
#   1. backfill — walks the fixture, PATCHes the marker onto the untagged
#      file, skips the tagged one. Asserts scanned=2 / patched=1 / skipped=1.
#   2. backfill again — idempotency. The once-untagged file is now tagged,
#      so the second run patches nothing. Asserts patched=0 / skipped=2.
#      This is what proves the untagged file ended up tagged.
#
# Drive HTTP is stubbed two ways:
#   - `DIMROOM_HARNESS_DRIVE_STUB=1` swaps in the OAuth-and-`/about` stub
#     HTTPClient so `applicationDidFinishLaunching` resolves a DriveClient
#     and wires the backfill collaborator.
#   - `DIMROOM_HARNESS_DRIVE_BACKFILL_FIXTURE=<json>` swaps the live
#     `DriveMarkerScanner` for a fixture-driven stub that serves a static
#     file list and records which ids get PATCHed (reflecting the marker
#     so a second run sees them tagged).
#
# Assumes the capture-screenshots skill already built the App and CLI
# binaries.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/backfill-markers}"
WORK_DIR="$REPO_ROOT/.artifacts/harness-backfill-markers"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
FIXTURE_PATH="$WORK_DIR/backfill-fixture.json"
SOCKET="/tmp/dimroom-harness-backfill-markers-$$.sock"
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
}

echo "=== Seeding catalog ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
"$FIXTURE_BIN" seed \
    --catalog "$CATALOG_PATH" \
    --cache "$PREVIEW_CACHE" \
    --seed-dir "$REPO_ROOT/fixtures/library-seed"

if [ ! -f "$CATALOG_PATH" ]; then
    echo "ERROR: dimroom-fixture did not produce $CATALOG_PATH"
    exit 1
fi

# Backfill fixture: one untagged (legacy) file and one already-tagged
# file. The stub serves these to the real DriveMarkerBackfill logic.
cat >"$FIXTURE_PATH" <<'JSON'
{
  "files": [
    {
      "id": "legacy-untagged-id",
      "name": "DSC_0001.jpg",
      "mimeType": "image/jpeg"
    },
    {
      "id": "already-tagged-id",
      "name": "DSC_0002.jpg",
      "mimeType": "image/jpeg",
      "appProperties": {"dimroom": "1"}
    }
  ]
}
JSON

mkdir -p "$SCREENSHOT_DIR"

echo "=== Launching app in harness mode ==="
# Staging-only flow: previously launched with no --originals-cache. Adopting
# the helper newly scopes originals to $WORK_DIR/originals (the #289/#331 leak
# fix), the intended behaviour change from #366/#382.
FIXTURE_CATALOG="$CATALOG_PATH"
HARNESS_WORK_DIR="$WORK_DIR"
HARNESS_ENV=(DIMROOM_HARNESS_DRIVE_STUB=1 DIMROOM_HARNESS_DRIVE_BACKFILL_FIXTURE="$FIXTURE_PATH")
harness_launch_app

echo "=== connect-drive — wire up the backfill collaborator ==="
CONNECT_OUT=$("$CLI_BIN" connect-drive --socket "$SOCKET")
echo "$CONNECT_OUT"
CONNECT_STATUS=$(printf '%s' "$CONNECT_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
if [ "$CONNECT_STATUS" != "connected" ]; then
    echo "ERROR: expected drive auth status 'connected', got '$CONNECT_STATUS'"
    exit 1
fi

echo "=== backfill-drive-markers — first run, expect patched=1 / skipped=1 ==="
RUN1_OUT=$("$CLI_BIN" backfill-drive-markers --socket "$SOCKET")
echo "$RUN1_OUT"
RUN1_SCANNED=$(printf '%s' "$RUN1_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.scanned')
RUN1_PATCHED=$(printf '%s' "$RUN1_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.patched')
RUN1_SKIPPED=$(printf '%s' "$RUN1_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.skipped')
if [ "$RUN1_SCANNED" != "2" ]; then
    echo "ERROR: expected scanned=2, got '$RUN1_SCANNED'"
    exit 1
fi
if [ "$RUN1_PATCHED" != "1" ]; then
    echo "ERROR: expected patched=1, got '$RUN1_PATCHED'"
    exit 1
fi
if [ "$RUN1_SKIPPED" != "1" ]; then
    echo "ERROR: expected skipped=1, got '$RUN1_SKIPPED'"
    exit 1
fi
echo "  OK: untagged file PATCHed, tagged file skipped"

take_screenshot "backfill-markers-first-run"

echo "=== backfill-drive-markers — second run, expect idempotent patched=0 / skipped=2 ==="
RUN2_OUT=$("$CLI_BIN" backfill-drive-markers --socket "$SOCKET")
echo "$RUN2_OUT"
RUN2_SCANNED=$(printf '%s' "$RUN2_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.scanned')
RUN2_PATCHED=$(printf '%s' "$RUN2_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.patched')
RUN2_SKIPPED=$(printf '%s' "$RUN2_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.skipped')
if [ "$RUN2_SCANNED" != "2" ]; then
    echo "ERROR: expected scanned=2, got '$RUN2_SCANNED'"
    exit 1
fi
if [ "$RUN2_PATCHED" != "0" ]; then
    echo "ERROR: expected patched=0 (idempotent), got '$RUN2_PATCHED'"
    exit 1
fi
if [ "$RUN2_SKIPPED" != "2" ]; then
    echo "ERROR: expected skipped=2 (both now tagged), got '$RUN2_SKIPPED'"
    exit 1
fi
echo "  OK: second run patched nothing — the once-untagged file is now tagged"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness backfill-markers flow PASSED ==="
