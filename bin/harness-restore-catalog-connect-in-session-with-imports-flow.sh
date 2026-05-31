#!/usr/bin/env bash
# harness-restore-catalog-connect-in-session-with-imports-flow.sh —
# Layer C flow for #371 (the #293 / #339 follow-up).
#
# Sibling of harness-restore-catalog-connect-in-session-flow.sh. That
# flow proves the same-session restore lands when the placeholder is
# empty. THIS flow proves the #293 guard: when the user imports into the
# placeholder between a FAILED launch-time OAuth and a later SUCCEEDED
# one, the interim imports SURVIVE the same-session restore instead of
# being clobbered by the remote catalog.
#
# The window only exists with two `--harness`-only seams (both #371):
#   * DIMROOM_HARNESS_GATE_WITHOUT_AUTOCONNECT=1 arms the same-session
#     restore gate at launch (`.offerConnectNoAuth`) WITHOUT auto-firing
#     the menu Connect flow, so the flow can drive the OAuth attempts
#     itself via `connect-drive` (the auto-connect path raises a blocking
#     NSAlert on failure, unusable here).
#   * DIMROOM_HARNESS_DRIVE_STUB_FAIL_FIRST_OAUTH=1 makes the stub
#     DriveClient deny the FIRST authorize attempt (redirect with
#     ?error=access_denied → DriveClientError.authorizationDenied) and
#     succeed on the second.
#
# Sequence:
#   1. Launch into an armed-gate empty placeholder (no auto-connect).
#      Assert state.assetCount == 0.
#   2. connect-drive → FAILS. DriveAuthState resets to `disconnected`
#      WITHOUT consuming the gate (the $status sink only fires on a
#      → .connected transition). Assert status == disconnected.
#   3. import-folder a 1-photo fixture into the placeholder. Assert
#      importedCount == 1 and state.assetCount == 1.
#   4. connect-drive → SUCCEEDS. The $status sink fires
#      runSameSessionRestore(); the #293 guard sees a non-empty
#      placeholder and SKIPS the teardown/restore. Assert
#      status == connected.
#   5. Poll state.assetCount over a settle window and assert it STAYS 1
#      (the restore is async off the sink). The remote stub holds 3
#      photos, so removing the guard would tear down and restore the
#      3-asset remote, flipping assetCount to 3 and failing this poll —
#      this is the AC#2 mutation-detecting assertion.
#   6. Assert the local catalog file still exists.
#
# OAuth runs through the existing harness stubs
# (DIMROOM_HARNESS_DRIVE_STUB=1), so there's no real Google traffic.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/restore-catalog-connect-in-session-with-imports}"
WORK_DIR="$REPO_ROOT/.artifacts/harness-restore-catalog-connect-in-session-with-imports"
REMOTE_CATALOG="$WORK_DIR/remote-catalog.sqlite"
REMOTE_PREVIEW_CACHE="$WORK_DIR/remote-previews"
LOCAL_CATALOG="$WORK_DIR/local/catalog.sqlite"
LOCAL_PREVIEW_CACHE="$WORK_DIR/local-previews"
# Scope the originals staging dir + LRU originals cache under $WORK_DIR so
# the interim import writes its downloads + index.json here, never into
# the user's real ~/Library/Application Support/Dimroom/originals (#331).
ORIGINALS_CACHE="$WORK_DIR/originals"
IMPORT_SOURCE="$REPO_ROOT/fixtures/loupe-small"
SOCKET="/tmp/dimroom-harness-restore-catalog-connect-in-session-imports-$$.sock"
APP_PID=""

# Remote stub holds 3 photos; the interim import adds exactly 1. The
# counts MUST differ so a guard regression (restore the 3-asset remote)
# is distinguishable from the kept-1-asset placeholder — see step 5.
REMOTE_COUNT=3
IMPORT_COUNT=1

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

assert_field() {
    # assert_field <label> <json> <path> <expected>
    local label="$1" json="$2" path="$3" expected="$4"
    local actual
    actual=$(printf '%s' "$json" | "$REPO_ROOT/bin/harness-json-extract" "$path")
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: $label — expected $path='$expected', got '$actual'"
        echo "  raw: $json"
        exit 1
    fi
    echo "  OK: $label ($path=$actual)"
}

echo "=== Seeding remote fixture catalog ($REMOTE_COUNT photos) ==="
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
printf '{"photoCount":%s}\n' "$REMOTE_COUNT" > "$REMOTE_CATALOG.json"

if [ ! -d "$IMPORT_SOURCE" ]; then
    echo "ERROR: import fixture $IMPORT_SOURCE missing"
    exit 1
fi

if [ -f "$LOCAL_CATALOG" ]; then
    echo "ERROR: local catalog $LOCAL_CATALOG already exists; the connect path wouldn't fire"
    exit 1
fi

# ---------------------------------------------------------------------
# Launch: armed gate, NO auto-connect, fail-first OAuth.
#
# DIMROOM_HARNESS_STUB_REMOTE_CATALOG_AT_LAUNCH is intentionally UNSET so
# the launch decision routes to `.offerConnectNoAuth`. The remote stub is
# present (DIMROOM_HARNESS_STUB_REMOTE_CATALOG) so a guard regression has
# a 3-asset catalog to restore from — making the regression observable.
# ---------------------------------------------------------------------
echo "=== Launching app — armed gate, no auto-connect, fail-first OAuth ==="
FIXTURE_CATALOG="$LOCAL_CATALOG"
PREVIEW_CACHE="$LOCAL_PREVIEW_CACHE"
HARNESS_WORK_DIR="$WORK_DIR"
HARNESS_ENV=(
    DIMROOM_HARNESS_DRIVE_STUB=1
    DIMROOM_HARNESS_DRIVE_STUB_FAIL_FIRST_OAUTH=1
    DIMROOM_HARNESS_GATE_WITHOUT_AUTOCONNECT=1
    DIMROOM_HARNESS_STUB_REMOTE_CATALOG="$REMOTE_CATALOG"
    DIMROOM_HARNESS_STUB_REMOTE_CATALOG_PHOTO_COUNT="$REMOTE_COUNT"
    DIMROOM_HARNESS_AUTO_CONFIRM_CONNECT_FOR_RESTORE=connect
)
harness_launch_app

echo "=== [1] Placeholder is empty before any import ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
assert_field "empty placeholder" "$STATE_OUT" "data.assetCount" "0"

echo "=== [2] connect-drive #1 — first OAuth attempt FAILS (gate not consumed) ==="
CONNECT1_OUT=$("$CLI_BIN" connect-drive --socket "$SOCKET")
echo "$CONNECT1_OUT"
assert_field "failed connect stays disconnected" "$CONNECT1_OUT" "data.status" "disconnected"

echo "=== [3] Import a 1-photo folder into the placeholder ==="
IMPORT_OUT=$("$CLI_BIN" import-folder "$IMPORT_SOURCE" --socket "$SOCKET")
echo "$IMPORT_OUT"
assert_field "import count" "$IMPORT_OUT" "data.importedCount" "$IMPORT_COUNT"
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
assert_field "placeholder after import" "$STATE_OUT" "data.assetCount" "$IMPORT_COUNT"

take_screenshot "restore-catalog-imports-before-second-connect"

echo "=== [4] connect-drive #2 — second OAuth attempt SUCCEEDS (fires same-session restore) ==="
CONNECT2_OUT=$("$CLI_BIN" connect-drive --socket "$SOCKET")
echo "$CONNECT2_OUT"
assert_field "second connect succeeds" "$CONNECT2_OUT" "data.status" "connected"

echo "=== [5] Imports SURVIVE the same-session restore — assetCount stays $IMPORT_COUNT ==="
# runSameSessionRestore() runs async off the $status sink after
# connect-drive returns. Poll over a settle window: with the #293 guard
# in place the placeholder's 1 asset is kept (skip path is a fast
# countAssets read). If the guard were removed, the teardown→restore
# would land the 3-asset remote within this window and trip the check.
for i in $(seq 1 8); do
    STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
    POLL_COUNT=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.assetCount')
    echo "  settle poll $i: assetCount=$POLL_COUNT"
    if [ "$POLL_COUNT" != "$IMPORT_COUNT" ]; then
        echo "ERROR: assetCount changed to '$POLL_COUNT' after second connect —"
        echo "       same-session restore clobbered the interim import (#293 guard regression)."
        exit 1
    fi
    sleep 1
done
echo "  OK: assetCount held at $IMPORT_COUNT across the settle window — imports survived"

echo "=== [6] Local catalog file survives (not deleted by a teardown) ==="
if [ ! -f "$LOCAL_CATALOG" ]; then
    echo "ERROR: local catalog $LOCAL_CATALOG was deleted — teardown ran despite non-empty placeholder"
    exit 1
fi
echo "  OK: local catalog present at $LOCAL_CATALOG"

take_screenshot "restore-catalog-imports-survive"

stop_app

echo "=== Harness restore-catalog connect-in-session-with-imports flow PASSED ==="
