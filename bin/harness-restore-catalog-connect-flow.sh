#!/usr/bin/env bash
# harness-restore-catalog-connect-flow.sh — Layer C flow for #256
# (wire "Connect Google Drive…" button on first-launch restore alert).
#
# Launches the app with no local catalog and no stub remote catalog, so
# the launch-time decision tree reaches `.offerConnectNoAuth`. The
# alert is pre-answered via DIMROOM_HARNESS_AUTO_CONFIRM_CONNECT_FOR_RESTORE
# (added in #256) — `connect` should trigger the same menu Connect flow
# after launch, transitioning the stub-auth state to `connected`.
# `skip` should leave the state at `disconnected`, proving the
# Start-Fresh path is unchanged.
#
# OAuth runs through the existing harness stubs
# (DIMROOM_HARNESS_DRIVE_STUB=1), so there's no real Google traffic.
#
# Assumes the capture-screenshots skill already built App and CLI binaries.
set -euo pipefail

EXPECTED_STUB_EMAIL="harness@example.test"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/restore-catalog-connect}"
WORK_DIR="$REPO_ROOT/.artifacts/harness-restore-catalog-connect"
LOCAL_CATALOG="$WORK_DIR/local/catalog.sqlite"
LOCAL_PREVIEW_CACHE="$WORK_DIR/local-previews"
SOCKET="/tmp/dimroom-harness-restore-catalog-connect-$$.sock"
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

wait_for_socket() {
    for i in $(seq 1 30); do
        if [ -e "$SOCKET" ]; then
            echo "Socket ready after ${i}s"
            return 0
        fi
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            echo "ERROR: App exited before socket was ready"
            exit 1
        fi
        sleep 1
    done
    echo "ERROR: Socket not ready after 30s"
    exit 1
}

stop_app() {
    "$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true
    sleep 1
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        echo "WARN: App did not exit after quit, killing"
        kill "$APP_PID" 2>/dev/null || true
    fi
    APP_PID=""
    rm -f "$SOCKET"
}

rm -rf "$WORK_DIR"
# Create the parent dir for the local catalog so `openCatalog` can
# create the file later (mirrors real first-launch where
# `resolveCatalogPath` mkdir's the default path). We do NOT create the
# catalog file itself — that's what triggers `.offerConnectNoAuth`.
mkdir -p "$WORK_DIR/local" "$SCREENSHOT_DIR"

# ---------------------------------------------------------------------
# Case 1: user picks "Connect Google Drive…" on the launch alert.
# Post-launch consumer should fire `connectGoogleDriveFromMenu()`, which
# under stub OAuth completes synchronously enough that polling
# `drive-auth-state` reaches `connected` within a few seconds.
# ---------------------------------------------------------------------

# Sanity: local path should NOT exist yet so the launch restore branch
# fires and reaches `.offerConnectNoAuth`.
if [ -f "$LOCAL_CATALOG" ]; then
    echo "ERROR: local catalog $LOCAL_CATALOG already exists; the restore branch wouldn't fire"
    exit 1
fi

echo "=== [connect] Launching app — no local catalog, stub OAuth, auto-confirm=connect ==="
# `AUTO_CONFIRM_RESTORE=1` (#283) silences the failure alert that
# would otherwise pop when the post-connect same-session restore
# probes Drive through the stub HTTPClient (which 404s every
# non-OAuth request — there is no remote catalog to find in this
# flow). The flow still proves the Connect button reaches `.connected`;
# the restore probe failure is incidental and out of scope here.
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_HARNESS_DRIVE_STUB=1 \
DIMROOM_HARNESS_AUTO_CONFIRM_CONNECT_FOR_RESTORE=connect \
DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=1 \
    "$APP_BIN" --harness \
    --fixture-catalog "$LOCAL_CATALOG" \
    --preview-cache "$LOCAL_PREVIEW_CACHE" &
APP_PID=$!
wait_for_socket

echo "=== [connect] Polling drive-auth-state until connected ==="
CONNECTED=""
for i in $(seq 1 20); do
    POLL_OUT=$("$CLI_BIN" drive-auth-state --socket "$SOCKET")
    POLL_STATUS=$(printf '%s' "$POLL_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
    echo "  attempt $i: status=$POLL_STATUS"
    if [ "$POLL_STATUS" = "connected" ]; then
        CONNECTED="yes"
        break
    fi
    sleep 1
done
if [ -z "$CONNECTED" ]; then
    echo "ERROR: drive-auth-state never reached 'connected' after Connect click"
    exit 1
fi

# The /about call returns the stub email — confirms the connect flow
# went all the way through `client.authenticate()` + refreshEmail().
CONNECT_EMAIL=$(printf '%s' "$POLL_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.email')
if [ "$CONNECT_EMAIL" != "$EXPECTED_STUB_EMAIL" ]; then
    echo "ERROR: expected email '$EXPECTED_STUB_EMAIL' after auto-connect, got '$CONNECT_EMAIL'"
    exit 1
fi
echo "  OK: status=connected, email=$CONNECT_EMAIL — Connect button wired to OAuth flow"

take_screenshot "restore-connect-after-launch"

stop_app

# ---------------------------------------------------------------------
# Case 2: user picks "Start Fresh". Status must stay `disconnected`,
# proving the existing skip path is unchanged.
# ---------------------------------------------------------------------

# Fresh workspace so the launch path again hits `.offerConnectNoAuth`.
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/local"

echo "=== [skip] Launching app — no local catalog, stub OAuth, auto-confirm=skip ==="
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_HARNESS_DRIVE_STUB=1 \
DIMROOM_HARNESS_AUTO_CONFIRM_CONNECT_FOR_RESTORE=skip \
    "$APP_BIN" --harness \
    --fixture-catalog "$LOCAL_CATALOG" \
    --preview-cache "$LOCAL_PREVIEW_CACHE" &
APP_PID=$!
wait_for_socket

# Give the (possibly-scheduled) post-launch consumer a chance to fire,
# so we're not racing it when we assert "still disconnected".
sleep 2

echo "=== [skip] drive-auth-state — assert still disconnected ==="
SKIP_OUT=$("$CLI_BIN" drive-auth-state --socket "$SOCKET")
echo "$SKIP_OUT"
SKIP_STATUS=$(printf '%s' "$SKIP_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
if [ "$SKIP_STATUS" != "disconnected" ]; then
    echo "ERROR: expected status 'disconnected' after Start Fresh, got '$SKIP_STATUS'"
    exit 1
fi
echo "  OK: status=disconnected — Start Fresh path unchanged"

take_screenshot "restore-skip-after-launch"

stop_app

echo "=== Harness restore-catalog-connect flow PASSED ==="
