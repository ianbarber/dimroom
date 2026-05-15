#!/usr/bin/env bash
# harness-drive-auth-stale-token-flow.sh — Layer C flow for the stale-token
# recovery path (#195).
#
# Verifies that injecting a refresh-token failure flips DriveAuthState back
# to `disconnected` so the UI can surface a re-auth prompt. Drives the
# transition deterministically via the harness `simulate-drive-auth-failure`
# command rather than waiting for a real revoked-token round-trip against
# Google.
#
# Assumes the capture-screenshots skill already built App and CLI binaries.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/drive-auth-stale-token}"
WORK_DIR="$REPO_ROOT/.artifacts/harness-drive-auth-stale-token"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-drive-auth-stale-$$.sock"
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
# In CI / harness runs the OAuth client may or may not be configured.
# Both outcomes are acceptable here — what we care about is that the
# command returns and reports a known status.
case "$INIT_STATUS" in
    disconnected|connected|connecting)
        echo "  OK: initial status = $INIT_STATUS"
        ;;
    *)
        echo "ERROR: unexpected initial status '$INIT_STATUS'"
        exit 1
        ;;
esac

take_screenshot "drive-auth-initial"

echo "=== simulate-drive-auth-failure — inject refresh failure ==="
FAIL_OUT=$("$CLI_BIN" simulate-drive-auth-failure --socket "$SOCKET")
echo "$FAIL_OUT"
if ! echo "$FAIL_OUT" | grep -q '"ok"'; then
    echo "ERROR: simulate-drive-auth-failure did not return ok"
    exit 1
fi

echo "=== drive-auth-state — assert disconnected after simulated failure ==="
POST_OUT=$("$CLI_BIN" drive-auth-state --socket "$SOCKET")
echo "$POST_OUT"
POST_STATUS=$(printf '%s' "$POST_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
if [ "$POST_STATUS" != "disconnected" ]; then
    echo "ERROR: expected status 'disconnected' after simulateDriveAuthFailure, got '$POST_STATUS'"
    exit 1
fi
echo "  OK: status = disconnected"

take_screenshot "drive-auth-after-simulated-failure"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness drive-auth stale-token flow PASSED ==="
