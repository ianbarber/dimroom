#!/usr/bin/env bash
# harness-restore-catalog-connect-in-session-flow.sh — Layer C flow
# for #283 (same-session catalog restore after launch-time Connect).
#
# Sibling of harness-restore-catalog-connect-flow.sh — the existing
# flow asserts the Connect button reaches `.connected`; this one
# asserts that the catalog actually restores in the same session,
# without a relaunch.
#
# Mechanics:
#   * Pre-seed a stub remote catalog (fixture-built) so a "Drive
#     catalog" exists.
#   * Launch with DIMROOM_HARNESS_STUB_REMOTE_CATALOG set but
#     DIMROOM_HARNESS_STUB_REMOTE_CATALOG_AT_LAUNCH **unset** — the
#     launch decision routes to `.offerConnectNoAuth` (the connect
#     button path) rather than `.attemptRestoreWithStub`.
#   * Pre-answer the connect alert via
#     DIMROOM_HARNESS_AUTO_CONFIRM_CONNECT_FOR_RESTORE=connect.
#   * Pre-answer the post-restore prompt via
#     DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=1.
#   * After socket up, poll drive-auth-state until `connected` (proves
#     the connect button still fires OAuth) and then poll `state` until
#     `assetCount == N` (proves the post-connect same-session restore
#     landed the remote catalog into the Library view).
#   * Re-launch with the now-present local catalog and assert
#     `assetCount == N` immediately — pins the idempotency criterion.
#
# OAuth runs through the existing harness stubs
# (DIMROOM_HARNESS_DRIVE_STUB=1), so there's no real Google traffic.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/restore-catalog-connect-in-session}"
WORK_DIR="$REPO_ROOT/.artifacts/harness-restore-catalog-connect-in-session"
REMOTE_CATALOG="$WORK_DIR/remote-catalog.sqlite"
REMOTE_PREVIEW_CACHE="$WORK_DIR/remote-previews"
LOCAL_CATALOG="$WORK_DIR/local/catalog.sqlite"
LOCAL_PREVIEW_CACHE="$WORK_DIR/local-previews"
# Scope the originals staging dir + LRU originals cache under $WORK_DIR so
# any originals fetch writes its downloads + index.json here, never into the
# user's real ~/Library/Application Support/Dimroom/originals (issue #331).
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-restore-catalog-connect-in-session-$$.sock"
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

echo "=== Seeding remote fixture catalog ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$WORK_DIR/local" "$ORIGINALS_CACHE" "$SCREENSHOT_DIR"

"$FIXTURE_BIN" seed \
    --catalog "$REMOTE_CATALOG" \
    --cache "$REMOTE_PREVIEW_CACHE" \
    --seed-dir "$REPO_ROOT/fixtures/library-seed"

if [ ! -f "$REMOTE_CATALOG" ]; then
    echo "ERROR: dimroom-fixture did not produce $REMOTE_CATALOG"
    exit 1
fi

EXPECTED_COUNT=3
printf '{"photoCount":%s}\n' "$EXPECTED_COUNT" > "$REMOTE_CATALOG.json"

if [ -f "$LOCAL_CATALOG" ]; then
    echo "ERROR: local catalog $LOCAL_CATALOG already exists; the connect path wouldn't fire"
    exit 1
fi

# ---------------------------------------------------------------------
# Case 1 (the core fix): launch into .offerConnectNoAuth, user picks
# Connect, post-connect sink re-runs restore in-session, assetCount
# reflects the remote catalog without relaunch.
#
# Note: DIMROOM_HARNESS_STUB_REMOTE_CATALOG_AT_LAUNCH is intentionally
# NOT set — the launch decision must reach `.offerConnectNoAuth`, not
# `.attemptRestoreWithStub`. The same env var the existing
# harness-restore-catalog-flow.sh uses to opt INTO launch-time restore
# is what we leave UNSET here.
# ---------------------------------------------------------------------

echo "=== [in-session] Launching app — no local catalog, stub OAuth, stub remote (post-connect only) ==="
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_HARNESS_DRIVE_STUB=1 \
DIMROOM_HARNESS_STUB_REMOTE_CATALOG="$REMOTE_CATALOG" \
DIMROOM_HARNESS_STUB_REMOTE_CATALOG_PHOTO_COUNT="$EXPECTED_COUNT" \
DIMROOM_HARNESS_AUTO_CONFIRM_CONNECT_FOR_RESTORE=connect \
DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=1 \
DIMROOM_ORIGINALS_DIR="$ORIGINALS_CACHE" \
    "$APP_BIN" --harness \
    --fixture-catalog "$LOCAL_CATALOG" \
    --preview-cache "$LOCAL_PREVIEW_CACHE" \
    --originals-cache "$ORIGINALS_CACHE" &
APP_PID=$!
wait_for_socket

echo "=== [in-session] Polling drive-auth-state until connected ==="
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
echo "  OK: status=connected"

echo "=== [in-session] Polling state.assetCount until restored ==="
RESTORED=""
for i in $(seq 1 20); do
    STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
    STATE_COUNT=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.assetCount')
    echo "  attempt $i: assetCount=$STATE_COUNT"
    if [ "$STATE_COUNT" = "$EXPECTED_COUNT" ]; then
        RESTORED="yes"
        break
    fi
    sleep 1
done
if [ -z "$RESTORED" ]; then
    echo "ERROR: state.assetCount never reached $EXPECTED_COUNT after Connect — same-session restore did not land"
    exit 1
fi
echo "  OK: state reports $STATE_COUNT assets after Connect — same-session restore landed"

echo "=== [in-session] Sanity: local catalog file now exists ==="
if [ ! -f "$LOCAL_CATALOG" ]; then
    echo "ERROR: local catalog $LOCAL_CATALOG not created by same-session restore"
    exit 1
fi
echo "  OK: local catalog present at $LOCAL_CATALOG"

take_screenshot "restore-catalog-after-in-session-connect"

stop_app

# ---------------------------------------------------------------------
# Case 2 (idempotency): re-launch with the now-present local catalog
# and assert assetCount immediately. The launch decision should hit
# `.skipLocalPresent` and never offer Connect; same-session restore
# must not fire because the gate is only set in `.offerConnectNoAuth`.
# ---------------------------------------------------------------------

echo "=== [re-launch] Local catalog now present — assert no re-prompt, assetCount stable ==="
if [ ! -f "$LOCAL_CATALOG" ]; then
    echo "ERROR: case 2 expected $LOCAL_CATALOG to survive stop_app, but it's gone"
    exit 1
fi

DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_HARNESS_DRIVE_STUB=1 \
DIMROOM_HARNESS_STUB_REMOTE_CATALOG="$REMOTE_CATALOG" \
DIMROOM_HARNESS_STUB_REMOTE_CATALOG_PHOTO_COUNT="$EXPECTED_COUNT" \
DIMROOM_ORIGINALS_DIR="$ORIGINALS_CACHE" \
    "$APP_BIN" --harness \
    --fixture-catalog "$LOCAL_CATALOG" \
    --preview-cache "$LOCAL_PREVIEW_CACHE" \
    --originals-cache "$ORIGINALS_CACHE" &
APP_PID=$!
wait_for_socket

STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
STATE_COUNT=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.assetCount')
if [ "$STATE_COUNT" != "$EXPECTED_COUNT" ]; then
    echo "ERROR: re-launch expected assetCount=$EXPECTED_COUNT, got '$STATE_COUNT'"
    exit 1
fi
echo "  OK: re-launch state reports $STATE_COUNT assets — local catalog reopened cleanly"

stop_app

echo "=== Harness restore-catalog-connect-in-session flow PASSED ==="
