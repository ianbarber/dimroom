#!/usr/bin/env bash
# harness-auto-upload-stub-flow.sh — Layer C coverage for #414 / AC1 of
# #270: with the auto-upload toggle ON and a stub `DriveUploading` +
# stub auth wired in (`--stub-drive-uploader`, see #414), importing a
# folder should drive `uploadCoordinatorPhase` to `done`. Without the
# stub, `harness-settings-flow` already proves the decision path is
# reached but the upload short-circuits at the missing-uploader guard;
# this flow proves the *full* path runs end-to-end.
#
# Assumes capture-screenshots skill has already built the app + CLI;
# this script never rebuilds.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
# shellcheck source=lib/harness-flow.sh
. "$REPO_ROOT/bin/lib/harness-flow.sh"

SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/auto-upload-stub}"
WORK_DIR="$REPO_ROOT/.artifacts/harness-auto-upload-stub"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
SOCKET="/tmp/dimroom-harness-auto-upload-stub-$$.sock"
# Isolated UserDefaults so the toggle write doesn't trample real prefs.
DEFAULTS_DOMAIN="com.dimroom.harness-auto-upload-stub-$$"
APP_PID=""

cleanup() {
    harness_cleanup
    defaults delete "$DEFAULTS_DOMAIN" 2>/dev/null || true
}
trap cleanup EXIT

harness_locate_binaries
harness_require_binaries "$APP_BIN" "$CLI_BIN" "$FIXTURE_BIN" || exit 1

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$PREVIEW_CACHE"
"$FIXTURE_BIN" seed \
    --catalog "$CATALOG_PATH" \
    --cache "$PREVIEW_CACHE" \
    --seed-dir "$SEED_SRC"

# Stage a single-image folder distinct from any other fixture so the
# import adds exactly one new asset (no dedup skip).
IMPORT_DIR="$WORK_DIR/import"
mkdir -p "$IMPORT_DIR"
cp "$REPO_ROOT/fixtures/import/IMG_0003.jpg" "$IMPORT_DIR/"

echo "=== Launching with --stub-drive-uploader ==="
FIXTURE_CATALOG="$CATALOG_PATH"
HARNESS_WORK_DIR="$WORK_DIR"
SETTINGS_SUITE="$DEFAULTS_DOMAIN"
HARNESS_FLAGS=(--stub-drive-uploader)
harness_launch_app

echo "=== Verify stub auth: drive-auth-state status must be 'connected' ==="
# The auth handoff is the *load-bearing* invariant of this flow. The
# phase check below is set by UploadCoordinator (the consumer); the
# auth state is set by HarnessStubDriveAuth (the handoff we're
# proving). A mismatch here means the stub didn't take effect and
# downstream assertions may pass for the wrong reasons. Poll briefly
# because hydrate() is dispatched on MainActor and may not have
# settled by the moment the socket accepts the first command.
DEADLINE=$(($(date +%s) + 5))
AUTH=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    AUTH_OUT=$("$CLI_BIN" drive-auth-state --socket "$SOCKET")
    AUTH=$(printf '%s' "$AUTH_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.status')
    if [ "$AUTH" = "connected" ]; then break; fi
    sleep 0.2
done
if [ "$AUTH" != "connected" ]; then
    echo "ERROR: expected drive-auth-state status 'connected' within 5s, got '$AUTH' — stub auth handoff did not take effect"
    exit 1
fi
echo "  OK: drive-auth-state reports connected (stub auth handoff in effect)"

echo "=== Toggle ON driveAutoUploadOriginals ==="
SET_OUT=$("$CLI_BIN" set-setting driveAutoUploadOriginals true --socket "$SOCKET")
if ! echo "$SET_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-setting driveAutoUploadOriginals true did not return ok"
    exit 1
fi
echo "  OK: toggle on"

echo "=== Import (expect importedCount=1, then uploadCoordinatorPhase=done) ==="
IMPORT_OUT=$("$CLI_BIN" import-folder "$IMPORT_DIR" --socket "$SOCKET")
echo "$IMPORT_OUT"
IMPORTED=$(printf '%s' "$IMPORT_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.importedCount')
if [ "$IMPORTED" != "1" ]; then
    echo "ERROR: expected importedCount 1, got '$IMPORTED'"
    exit 1
fi

# Poll uploadCoordinatorPhase up to ~10s — AutoUploadAfterImport runs in
# a Task spawned from the post-import .done branch, so the phase
# transition is asynchronous relative to the import-folder reply.
DEADLINE=$(($(date +%s) + 10))
PHASE=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
    PHASE=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.uploadCoordinatorPhase')
    if [ "$PHASE" = "done" ]; then break; fi
    sleep 0.2
done

if [ "$PHASE" != "done" ]; then
    echo "ERROR: expected uploadCoordinatorPhase 'done' within 10s, got '$PHASE'"
    exit 1
fi
echo "  OK: stubbed upload completed, uploadCoordinatorPhase=done"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

echo
echo "=== PASS: auto-upload runs end-to-end through the stub uploader ==="
