#!/usr/bin/env bash
# harness-drive-auth-flow.sh — Layer C flow for the Drive auth menu state (#166, #194).
#
# Verifies the menu-bound `connectDrive` / `disconnectDrive` / `driveAuthState`
# commands are scriptable end-to-end: starts the app in harness mode with the
# stub OAuth components (DIMROOM_HARNESS_DRIVE_STUB=1), drives the full
# disconnected → connecting → connected → disconnected cycle, and captures
# screenshots at each stable state.
#
# The stubs replace the browser launcher and HTTPClient inside `DriveClient`
# so `authenticate()` runs through its real code path without real Google
# traffic — see `Packages/DriveClient/Sources/DriveClient/HarnessOAuthStubs.swift`.
#
# Assumes the capture-screenshots skill already built App and CLI binaries.
set -euo pipefail

# Email the stub `HTTPClient` returns from `/drive/v3/about`. Pinned here
# so the assertion below stays in sync with `HarnessStubHTTPClient`'s
# default `email:` argument.
EXPECTED_STUB_EMAIL="harness@example.test"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/drive-auth}"
WORK_DIR="$REPO_ROOT/.artifacts/harness-drive-auth"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-drive-auth-$$.sock"
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

mkdir -p "$SCREENSHOT_DIR"

echo "=== Launching app in harness mode ==="
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_HARNESS_DRIVE_STUB=1 \
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

echo "=== drive-auth-state — initial status ==="
INIT_OUT=$("$CLI_BIN" drive-auth-state --socket "$SOCKET")
echo "$INIT_OUT"
INIT_STATUS=$(printf '%s' "$INIT_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
# Stub mode boots with an empty `InMemoryTokenStore`, so the hydrated
# status must be `disconnected` before we drive the connect path.
if [ "$INIT_STATUS" != "disconnected" ]; then
    echo "ERROR: expected initial status 'disconnected' under stub OAuth, got '$INIT_STATUS'"
    exit 1
fi
echo "  OK: initial status = disconnected"

take_screenshot "drive-auth-initial"

echo "=== connect-drive — assert full OAuth round-trip through stubs ==="
CONNECT_OUT=$("$CLI_BIN" connect-drive --socket "$SOCKET")
echo "$CONNECT_OUT"
CONNECT_STATUS=$(printf '%s' "$CONNECT_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
CONNECT_EMAIL=$(printf '%s' "$CONNECT_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.email')
if [ "$CONNECT_STATUS" != "connected" ]; then
    echo "ERROR: expected status 'connected' after connectDrive, got '$CONNECT_STATUS'"
    exit 1
fi
if [ "$CONNECT_EMAIL" != "$EXPECTED_STUB_EMAIL" ]; then
    echo "ERROR: expected email '$EXPECTED_STUB_EMAIL' after connectDrive, got '$CONNECT_EMAIL'"
    exit 1
fi
echo "  OK: status = connected, email = $CONNECT_EMAIL"

take_screenshot "drive-auth-connected"

echo "=== disconnect-drive — assert disconnect from connected state ==="
DISC_OUT=$("$CLI_BIN" disconnect-drive --socket "$SOCKET")
echo "$DISC_OUT"
if ! echo "$DISC_OUT" | grep -q '"ok"'; then
    echo "ERROR: disconnect-drive did not return ok"
    exit 1
fi

echo "=== drive-auth-state — assert disconnected after disconnect ==="
POST_OUT=$("$CLI_BIN" drive-auth-state --socket "$SOCKET")
echo "$POST_OUT"
POST_STATUS=$(printf '%s' "$POST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
if [ "$POST_STATUS" != "disconnected" ]; then
    echo "ERROR: expected status 'disconnected' after disconnectDrive, got '$POST_STATUS'"
    exit 1
fi
echo "  OK: status = disconnected"

take_screenshot "drive-auth-after-disconnect"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness drive-auth flow PASSED ==="
