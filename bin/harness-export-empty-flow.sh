#!/usr/bin/env bash
# harness-export-empty-flow.sh — Layer C flow for the zero-asset export
# response shape (#242 AC #2).
#
# Boots the app in harness mode against a fresh, empty fixture catalog
# and exports without importing anything. Asserts the response is `ok`
# with `exportedCount == 0` and the coordinator reaches its terminal
# phase. This is the JSON-layer proxy for "the post-export alert appears
# even when 0 photos were exported" — the alert itself isn't harness-
# drivable, but a regression that silently bails before the terminal
# phase would surface here as either an error status or a missing field.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_DIR="$REPO_ROOT/.artifacts/harness-export-empty"
CATALOG_COPY="$ARTIFACT_DIR/catalog.sqlite"
ORIGINALS_DIR="$ARTIFACT_DIR/originals"
EXPORT_DIR="$ARTIFACT_DIR/exported"
SOCKET="/tmp/dimroom-harness-export-empty-$$.sock"
APP_PID=""

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET"
}
trap cleanup EXIT

assert_json_field() {
    local label="$1" json="$2" field="$3" expected="$4"
    local actual
    actual=$(printf '%s' "$json" | "$REPO_ROOT/bin/harness-json-extract" "$field")
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: $label — expected $field == $expected, got $actual"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — $field == $expected"
}

echo "=== Building App ==="
swift build --package-path "$REPO_ROOT/App" 2>&1

echo "=== Building CLI ==="
swift build --package-path "$REPO_ROOT/Packages/Harness" --product dimroom-cli 2>&1

APP_BIN="$REPO_ROOT/App/.build/debug/Dimroom"
CLI_BIN="$REPO_ROOT/Packages/Harness/.build/debug/dimroom-cli"

if [ ! -x "$APP_BIN" ]; then
    echo "ERROR: App binary not found at $APP_BIN"
    exit 1
fi
if [ ! -x "$CLI_BIN" ]; then
    echo "ERROR: CLI binary not found at $CLI_BIN"
    exit 1
fi

echo "=== Preparing working directories ==="
rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR" "$ORIGINALS_DIR" "$EXPORT_DIR"
rm -f "$CATALOG_COPY"

echo "=== Launching app in harness mode (empty catalog) ==="
# Same auto-confirm short-circuit as harness-export-flow.sh — see that
# script for the explanation.
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_ORIGINALS_DIR="$ORIGINALS_DIR" \
DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0 \
"$APP_BIN" --harness --fixture-catalog "$CATALOG_COPY" &
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

echo "=== Scope = all (no imports — list should be empty) ==="
"$CLI_BIN" set-scope --socket "$SOCKET" > /dev/null

LIST_OUT=$("$CLI_BIN" list-assets --socket "$SOCKET")
echo "$LIST_OUT"
assert_json_field "list-assets status" "$LIST_OUT" "status" "ok"

if [ -n "${SCREENSHOT_DIR:-}" ]; then
    mkdir -p "$SCREENSHOT_DIR"
    "$CLI_BIN" screenshot "$SCREENSHOT_DIR/library-empty-before-export.png" --socket "$SOCKET" > /dev/null || true
fi

echo "=== Export with no assets (expect ok + exportedCount=0) ==="
EXPORT_OUT=$("$CLI_BIN" export "$EXPORT_DIR" --format jpeg --socket "$SOCKET")
echo "$EXPORT_OUT"
# The whole point of #242 AC #2: the coordinator must reach `.done`
# (not silently bail) so the user sees an alert. The harness analogue
# is a successful `ok` response with explicit zero counts.
assert_json_field "empty export status" "$EXPORT_OUT" "status" "ok"
assert_json_field "empty export exportedCount" "$EXPORT_OUT" "data.exportedCount" "0"
assert_json_field "empty export skippedCount" "$EXPORT_OUT" "data.skippedCount" "0"
assert_json_field "empty export failedCount" "$EXPORT_OUT" "data.failedCount" "0"

JPG_COUNT=$(find "$EXPORT_DIR" -name "*.jpg" | wc -l | tr -d ' ')
if [ "$JPG_COUNT" -ne 0 ]; then
    echo "ERROR: Expected 0 .jpg files in empty export, found $JPG_COUNT"
    ls -la "$EXPORT_DIR"
    exit 1
fi
echo "  OK: empty export produced 0 .jpg files (and a terminal-phase response)"

echo "=== Quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness export-empty flow PASSED ==="
