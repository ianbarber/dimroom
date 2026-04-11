#!/usr/bin/env bash
# harness-smoke.sh — Layer C smoke test for the harness control surface.
# Builds the app and CLI, launches in harness mode, sends basic commands,
# verifies responses and screenshot output, then cleans up.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOCKET="/tmp/dimroom-harness-smoke-$$.sock"
SCREENSHOT_DIR="$REPO_ROOT/.artifacts/smoke"
SCREENSHOT_PATH="$SCREENSHOT_DIR/smoke.png"
FIXTURE_CATALOG="$REPO_ROOT/fixtures/empty.sqlite"
APP_PID=""

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET"
}
trap cleanup EXIT

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

echo "=== Launching app in harness mode ==="
# Set the socket path via env so the app uses our test socket
DIMROOM_HARNESS_SOCKET="$SOCKET" "$APP_BIN" --harness --fixture-catalog "$FIXTURE_CATALOG" &
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

echo "=== Sending 'state' command ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET" 2>&1)
echo "$STATE_OUT"
if ! echo "$STATE_OUT" | grep -q '"ok"'; then
    echo "ERROR: state command did not return ok"
    exit 1
fi

echo "=== Sending 'navigate develop' command ==="
NAV_OUT=$("$CLI_BIN" navigate develop --socket "$SOCKET" 2>&1)
echo "$NAV_OUT"
if ! echo "$NAV_OUT" | grep -q '"ok"'; then
    echo "ERROR: navigate command did not return ok"
    exit 1
fi

echo "=== Sending 'screenshot' command ==="
mkdir -p "$SCREENSHOT_DIR"
SHOT_OUT=$("$CLI_BIN" screenshot "$SCREENSHOT_PATH" --socket "$SOCKET" 2>&1)
echo "$SHOT_OUT"
if ! echo "$SHOT_OUT" | grep -q '"ok"'; then
    echo "ERROR: screenshot command did not return ok"
    exit 1
fi

if [ ! -f "$SCREENSHOT_PATH" ]; then
    echo "ERROR: Screenshot file not created at $SCREENSHOT_PATH"
    exit 1
fi

# Verify it's a valid PNG
FILE_TYPE=$(file -b "$SCREENSHOT_PATH")
if ! echo "$FILE_TYPE" | grep -qi "png"; then
    echo "ERROR: Screenshot is not a valid PNG: $FILE_TYPE"
    exit 1
fi
echo "Screenshot verified: $FILE_TYPE"

echo "=== Sending 'quit' command ==="
QUIT_OUT=$("$CLI_BIN" quit --socket "$SOCKET" 2>&1) || true
echo "$QUIT_OUT"

# Wait for app to exit
sleep 2
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness smoke test PASSED ==="
