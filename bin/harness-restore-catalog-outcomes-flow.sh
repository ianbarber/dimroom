#!/usr/bin/env bash
# harness-restore-catalog-outcomes-flow.sh — Layer C coverage for #257
# (exercise restoreCatalogFromDrive harness command in non-
# `localCatalogPresent` branches).
#
# The existing harness-restore-catalog-flow.sh only asserts
# `localCatalogPresent` because the launch-time `attemptCatalogRestore`
# always succeeds before the harness socket opens. This flow sets
# `DIMROOM_HARNESS_SKIP_LAUNCH_RESTORE=1` so the launch path leaves
# the catalog genuinely absent, then drives `restore-catalog-from-drive`
# explicitly to assert each return-value branch:
#
#   Launch A (normal stub destination):
#     1. socket opens with no local catalog on disk
#     2. `--decline` → outcome=declinedByUser, photoCount=3, local
#        catalog still absent
#     3. `--confirm` → outcome=restored, photoCount=3,
#        downloadedBytes>0, driveFileId=stub-remote-catalog, local
#        catalog now present
#     4. `--confirm` again → outcome=localCatalogPresent (sanity: a
#        second invocation does not re-trigger restore)
#
#   Launch B (destination directory chmod 555):
#     1. socket opens with no local catalog
#     2. `--confirm` → outcome=restoreFailed, error non-empty
#       (download's copyItem hits EACCES on the read-only dir).
#     3. cleanup chmod 755 so `rm -rf` can succeed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/restore-catalog-outcomes}"
WORK_DIR="$REPO_ROOT/.artifacts/harness-restore-catalog-outcomes"
REMOTE_CATALOG="$WORK_DIR/remote-catalog.sqlite"
REMOTE_PREVIEW_CACHE="$WORK_DIR/remote-previews"
LAUNCH_A_DIR="$WORK_DIR/launch-a"
LAUNCH_A_LOCAL="$LAUNCH_A_DIR/local/catalog.sqlite"
LAUNCH_A_PREVIEWS="$LAUNCH_A_DIR/previews"
LAUNCH_B_DIR="$WORK_DIR/launch-b"
LAUNCH_B_LOCAL_DIR="$LAUNCH_B_DIR/local"
LAUNCH_B_LOCAL="$LAUNCH_B_LOCAL_DIR/catalog.sqlite"
LAUNCH_B_PREVIEWS="$LAUNCH_B_DIR/previews"
SOCKET="/tmp/dimroom-harness-restore-catalog-outcomes-$$.sock"
APP_PID=""

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET"
    # Restore write permission so `rm -rf` can clean up between runs;
    # the failure-injection chmod 555 would otherwise stick.
    if [ -d "$LAUNCH_B_LOCAL_DIR" ]; then
        chmod -R u+w "$LAUNCH_B_LOCAL_DIR" 2>/dev/null || true
    fi
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

wait_for_socket() {
    local pid="$1"
    for i in $(seq 1 30); do
        if [ -e "$SOCKET" ]; then
            echo "Socket ready after ${i}s"
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "ERROR: App exited before socket was ready"
            return 1
        fi
        sleep 1
    done
    echo "ERROR: Socket not ready after 30s"
    return 1
}

terminate_app() {
    "$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true
    sleep 1
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        echo "WARN: App did not exit after quit, killing"
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    APP_PID=""
    rm -f "$SOCKET"
}

echo "=== Seeding shared remote fixture catalog ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$SCREENSHOT_DIR"

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

###############################################################################
# Launch A — normal stub destination. Exercises declinedByUser, restored,
# and the localCatalogPresent short-circuit on repeated invocation.
###############################################################################

echo "=== Launch A — app in harness mode with launch-time restore skipped ==="
mkdir -p "$LAUNCH_A_DIR"

if [ -f "$LAUNCH_A_LOCAL" ]; then
    echo "ERROR: launch-a local catalog $LAUNCH_A_LOCAL already exists"
    exit 1
fi

DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_HARNESS_DRIVE_STUB=1 \
DIMROOM_HARNESS_STUB_REMOTE_CATALOG="$REMOTE_CATALOG" \
DIMROOM_HARNESS_STUB_REMOTE_CATALOG_PHOTO_COUNT="$EXPECTED_COUNT" \
DIMROOM_HARNESS_SKIP_LAUNCH_RESTORE=1 \
    "$APP_BIN" --harness \
    --fixture-catalog "$LAUNCH_A_LOCAL" \
    --preview-cache "$LAUNCH_A_PREVIEWS" &
APP_PID=$!

wait_for_socket "$APP_PID"

echo "=== Assert local catalog absent — the skip env var must keep openCatalog from creating it ==="
if [ -f "$LAUNCH_A_LOCAL" ]; then
    echo "ERROR: launch-a local catalog $LAUNCH_A_LOCAL exists after socket opened — DIMROOM_HARNESS_SKIP_LAUNCH_RESTORE did not suppress the launch path"
    exit 1
fi
echo "  OK: no local catalog yet — launch path skipped"

echo "=== restore-catalog-from-drive --decline ==="
DECLINE_OUT=$("$CLI_BIN" restore-catalog-from-drive --decline --socket "$SOCKET")
echo "$DECLINE_OUT"
DECLINE_OUTCOME=$(printf '%s' "$DECLINE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.outcome')
if [ "$DECLINE_OUTCOME" != "declinedByUser" ]; then
    echo "ERROR: expected outcome=declinedByUser, got '$DECLINE_OUTCOME'"
    exit 1
fi
DECLINE_PHOTOS=$(printf '%s' "$DECLINE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.photoCount')
if [ "$DECLINE_PHOTOS" != "$EXPECTED_COUNT" ]; then
    echo "ERROR: expected photoCount=$EXPECTED_COUNT in decline payload, got '$DECLINE_PHOTOS'"
    exit 1
fi
if [ -f "$LAUNCH_A_LOCAL" ]; then
    echo "ERROR: declined restore left a local catalog at $LAUNCH_A_LOCAL"
    exit 1
fi
echo "  OK: outcome=declinedByUser, photoCount=$DECLINE_PHOTOS, no local file"

echo "=== restore-catalog-from-drive --confirm — assert restored payload ==="
RESTORE_OUT=$("$CLI_BIN" restore-catalog-from-drive --confirm --socket "$SOCKET")
echo "$RESTORE_OUT"
RESTORE_OUTCOME=$(printf '%s' "$RESTORE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.outcome')
if [ "$RESTORE_OUTCOME" != "restored" ]; then
    echo "ERROR: expected outcome=restored, got '$RESTORE_OUTCOME'"
    exit 1
fi
RESTORE_PHOTOS=$(printf '%s' "$RESTORE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.photoCount')
if [ "$RESTORE_PHOTOS" != "$EXPECTED_COUNT" ]; then
    echo "ERROR: expected photoCount=$EXPECTED_COUNT in restored payload, got '$RESTORE_PHOTOS'"
    exit 1
fi
RESTORE_BYTES=$(printf '%s' "$RESTORE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.downloadedBytes')
if [ -z "$RESTORE_BYTES" ] || [ "$RESTORE_BYTES" -le 0 ]; then
    echo "ERROR: expected downloadedBytes > 0, got '$RESTORE_BYTES'"
    exit 1
fi
RESTORE_FILE_ID=$(printf '%s' "$RESTORE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.driveFileId')
if [ "$RESTORE_FILE_ID" != "stub-remote-catalog" ]; then
    echo "ERROR: expected driveFileId=stub-remote-catalog, got '$RESTORE_FILE_ID'"
    exit 1
fi
if [ ! -f "$LAUNCH_A_LOCAL" ]; then
    echo "ERROR: restored outcome but local catalog $LAUNCH_A_LOCAL not present"
    exit 1
fi
echo "  OK: outcome=restored, photoCount=$RESTORE_PHOTOS, downloadedBytes=$RESTORE_BYTES, driveFileId=$RESTORE_FILE_ID"

echo "=== restore-catalog-from-drive --confirm (again) — assert localCatalogPresent short-circuit ==="
REPEAT_OUT=$("$CLI_BIN" restore-catalog-from-drive --confirm --socket "$SOCKET")
echo "$REPEAT_OUT"
REPEAT_OUTCOME=$(printf '%s' "$REPEAT_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.outcome')
if [ "$REPEAT_OUTCOME" != "localCatalogPresent" ]; then
    echo "ERROR: expected outcome=localCatalogPresent on second restore, got '$REPEAT_OUTCOME'"
    exit 1
fi
echo "  OK: repeated invocation reports localCatalogPresent"

echo "=== screenshot ==="
SHOT_OUT=$("$CLI_BIN" screenshot "$SCREENSHOT_DIR/launch-a-after-restore.png" --socket "$SOCKET")
echo "$SHOT_OUT"
if ! echo "$SHOT_OUT" | grep -q '"ok"'; then
    echo "ERROR: screenshot command did not return ok"
    exit 1
fi

terminate_app

###############################################################################
# Launch B — destination directory is read-only so download fails. Asserts
# the restoreFailed outcome and the surfaced error string.
###############################################################################

echo "=== Launch B — destination directory chmod 555 so download fails ==="
mkdir -p "$LAUNCH_B_LOCAL_DIR"
chmod 555 "$LAUNCH_B_LOCAL_DIR"
if [ -f "$LAUNCH_B_LOCAL" ]; then
    echo "ERROR: launch-b local catalog $LAUNCH_B_LOCAL exists pre-launch"
    exit 1
fi

DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_HARNESS_DRIVE_STUB=1 \
DIMROOM_HARNESS_STUB_REMOTE_CATALOG="$REMOTE_CATALOG" \
DIMROOM_HARNESS_STUB_REMOTE_CATALOG_PHOTO_COUNT="$EXPECTED_COUNT" \
DIMROOM_HARNESS_SKIP_LAUNCH_RESTORE=1 \
    "$APP_BIN" --harness \
    --fixture-catalog "$LAUNCH_B_LOCAL" \
    --preview-cache "$LAUNCH_B_PREVIEWS" &
APP_PID=$!

wait_for_socket "$APP_PID"

echo "=== restore-catalog-from-drive --confirm — expect restoreFailed ==="
FAIL_OUT=$("$CLI_BIN" restore-catalog-from-drive --confirm --socket "$SOCKET")
echo "$FAIL_OUT"
FAIL_OUTCOME=$(printf '%s' "$FAIL_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.outcome')
if [ "$FAIL_OUTCOME" != "restoreFailed" ]; then
    echo "ERROR: expected outcome=restoreFailed for read-only destination, got '$FAIL_OUTCOME'"
    exit 1
fi
FAIL_ERROR=$(printf '%s' "$FAIL_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.error')
if [ -z "$FAIL_ERROR" ]; then
    echo "ERROR: expected non-empty data.error on restoreFailed, got empty string"
    exit 1
fi
echo "  OK: outcome=restoreFailed, error='$FAIL_ERROR'"

terminate_app

echo "=== Harness restore-catalog-outcomes flow PASSED ==="
