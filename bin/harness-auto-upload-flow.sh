#!/usr/bin/env bash
# harness-auto-upload-flow.sh — Layer C end-to-end coverage of #270 AC1
# ("with the toggle on and Drive connected, importing a folder triggers
# UploadCoordinator.run"), the gap called out in #414.
#
# The sibling harness-settings-flow.sh exercises the same post-import
# decision path with NO real uploader and disconnected auth, so its
# toggle-on branch deterministically short-circuits and uploadCoordinatorPhase
# stays "idle" — proving the wiring is reached but NOT that the upload runs.
#
# This flow launches with --stub-drive-uploader, which (a) injects a
# no-network HarnessStubDriveUploader and (b) flips driveAuthState to
# connected. Now guards #2 (isConnected) and #3 (uploader != nil) of
# AutoUploadAfterImport pass, so a toggle-on import runs UploadCoordinator.run
# to completion and uploadCoordinatorPhase reaches "done".
#
# Two assertions, ordered so the toggle is the only changing variable:
#   Step A — toggle OFF, import → phase stays "idle" (the opt-in gate still
#            holds even though uploader + auth are now satisfied);
#   Step B — toggle ON,  import → phase becomes "done" (AC1: full branch runs).
#
# handleImportFolder awaits runIfEnabled → UploadCoordinator.run before
# returning the import response, so the upload has already completed by the
# time the following `state` read lands — no polling needed.
#
# Assumes the capture-screenshots skill already built the App + CLI; this
# script never rebuilds.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
# shellcheck source=lib/harness-flow.sh
. "$REPO_ROOT/bin/lib/harness-flow.sh"

SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/auto-upload}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-auto-upload"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-auto-upload-$$.sock"
# Isolated UserDefaults suite so toggling driveAutoUploadOriginals can't
# trample the user's real Dimroom preferences.
DEFAULTS_DOMAIN="com.dimroom.harness-auto-upload-$$"
APP_PID=""

cleanup() {
    harness_cleanup
    defaults delete "$DEFAULTS_DOMAIN" 2>/dev/null || true
}
trap cleanup EXIT

harness_locate_binaries
harness_require_binaries "$APP_BIN" "$CLI_BIN" "$FIXTURE_BIN" || exit 1

launch_app() {
    FIXTURE_CATALOG="$CATALOG_PATH"
    HARNESS_WORK_DIR="$WORK_DIR"
    SETTINGS_SUITE="$DEFAULTS_DOMAIN"
    # Hermetic Drive: DISABLE_DRIVE forces resolveDriveClient -> nil so no real
    # client resolves on dev machines. That matters because a resolved client
    # spawns an async driveAuthState.hydrate() that would otherwise race the
    # flag's synchronous markConnectedForTesting() flip and reset auth to
    # disconnected (no stored token), short-circuiting the upload. With no real
    # client, the synthetic connected state and the injected stub uploader are
    # the only Drive surface — fully deterministic on CI and locally.
    HARNESS_ENV=(DIMROOM_HARNESS_DISABLE_DRIVE=1)
    # The headline flag: inject the no-network stub uploader + connected auth.
    HARNESS_FLAGS=(--stub-drive-uploader)
    harness_launch_app
}

# Import a single-image folder and return the import response JSON on stdout.
# The image differs from fixtures/library-seed, so it adds one new asset.
import_one() {
    local folder="$1"
    "$CLI_BIN" import-folder "$folder" --socket "$SOCKET"
}

phase_now() {
    "$CLI_BIN" state --socket "$SOCKET" \
        | "$REPO_ROOT/bin/harness-json-extract" 'data.uploadCoordinatorPhase'
}

echo "=== Seeding catalog from $SEED_SRC ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$SCREENSHOT_DIR"
"$FIXTURE_BIN" seed \
    --catalog "$CATALOG_PATH" \
    --cache "$PREVIEW_CACHE" \
    --seed-dir "$SEED_SRC"

if [ ! -f "$CATALOG_PATH" ]; then
    echo "ERROR: dimroom-fixture did not produce $CATALOG_PATH"
    exit 1
fi

# Stage two single-image folders whose contents hash differently from the
# seed, so each import adds exactly one new asset rather than dedup-skipping.
IMPORT_OFF="$WORK_DIR/import-off"
IMPORT_ON="$WORK_DIR/import-on"
mkdir -p "$IMPORT_OFF" "$IMPORT_ON"
cp "$REPO_ROOT/fixtures/import/IMG_0001.jpg" "$IMPORT_OFF/"
cp "$REPO_ROOT/fixtures/import/IMG_0002.jpg" "$IMPORT_ON/"

echo "=== Launching app (--stub-drive-uploader) ==="
launch_app

# Sanity: the flag flips auth to connected, but with the toggle off the
# decision helper bails at the opt-in gate. Run this first (while phase is
# still idle) so the assertion isn't confused by a prior .done.
echo "=== Step A: toggle OFF, import (expect 1 imported, phase idle) ==="
SET_OUT=$("$CLI_BIN" set-setting driveAutoUploadOriginals false --socket "$SOCKET")
if ! echo "$SET_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-setting driveAutoUploadOriginals false did not return ok"
    exit 1
fi
IMPORT_OUT=$(import_one "$IMPORT_OFF")
echo "$IMPORT_OUT"
assert_json_field "toggle-off import" "$IMPORT_OUT" 'data.importedCount' '1'
PHASE=$(phase_now)
if [ "$PHASE" != "idle" ]; then
    echo "ERROR: toggle-off import should leave uploadCoordinatorPhase idle, got '$PHASE'"
    exit 1
fi
echo "  OK: toggle-off import added 1 asset, phase idle (opt-in gate holds)"

echo "=== Step B: toggle ON, import (expect 1 imported, phase done) ==="
SET_OUT=$("$CLI_BIN" set-setting driveAutoUploadOriginals true --socket "$SOCKET")
if ! echo "$SET_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-setting driveAutoUploadOriginals true did not return ok"
    exit 1
fi
IMPORT_OUT=$(import_one "$IMPORT_ON")
echo "$IMPORT_OUT"
assert_json_field "toggle-on import" "$IMPORT_OUT" 'data.importedCount' '1'
# The decisive assertion (#270 AC1): with the toggle on, a real (stub)
# uploader, and connected auth, the auto-upload branch runs to completion.
PHASE=$(phase_now)
if [ "$PHASE" != "done" ]; then
    echo "ERROR: toggle-on import (stub uploader + connected) must drive phase to done, got '$PHASE'"
    echo "Last state:"; "$CLI_BIN" state --socket "$SOCKET"
    exit 1
fi
echo "  OK: toggle-on import drove uploadCoordinatorPhase to done (auto-upload ran end-to-end)"

echo "=== screenshot: auto-upload-done ==="
SHOT_PATH="$SCREENSHOT_DIR/auto-upload-done.png"
SHOT_OUT=$("$CLI_BIN" screenshot "$SHOT_PATH" --socket "$SOCKET")
echo "$SHOT_OUT"
if ! echo "$SHOT_OUT" | grep -q '"ok"'; then
    echo "ERROR: screenshot command did not return ok"
    exit 1
fi
if [ ! -f "$SHOT_PATH" ]; then
    echo "ERROR: screenshot file not created at $SHOT_PATH"
    exit 1
fi

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true
sleep 1

echo "=== Harness auto-upload flow PASSED ==="
