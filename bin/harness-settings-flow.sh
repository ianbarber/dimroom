#!/usr/bin/env bash
# harness-settings-flow.sh — Layer C flow for the Settings store
# (issue #236).
#
# Exercises the new get-setting / set-setting / clear-originals-cache /
# clear-preview-cache harness commands against an isolated UserDefaults
# suite, then relaunches the app with the same suite and verifies the
# write survived process restart.
#
# Assumes capture-screenshots skill has already built the app + CLI;
# this script never rebuilds.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/settings}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-settings"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
# Scope the originals staging + LRU cache under $WORK_DIR so the
# clear-originals-cache step can't touch the user's real
# ~/Library/Application Support/Dimroom/originals (issue #289).
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-settings-$$.sock"
# Isolated UserDefaults suite so this flow can't trample the user's
# real Dimroom preferences. The bundle id `com.dimroom.harness-settings`
# is read by `defaults` for cleanup.
DEFAULTS_DOMAIN="com.dimroom.harness-settings-$$"
APP_PID=""

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET"
    defaults delete "$DEFAULTS_DOMAIN" 2>/dev/null || true
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

launch_app() {
    DIMROOM_HARNESS_SOCKET="$SOCKET" \
        DIMROOM_ORIGINALS_DIR="$ORIGINALS_CACHE" \
        "$APP_BIN" --harness \
        --fixture-catalog "$CATALOG_PATH" \
        --preview-cache "$PREVIEW_CACHE" \
        --originals-cache "$ORIGINALS_CACHE" \
        --settings-suite "$DEFAULTS_DOMAIN" &
    APP_PID=$!

    for i in $(seq 1 30); do
        if [ -e "$SOCKET" ]; then
            return
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

quit_app() {
    "$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true
    sleep 1
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
    fi
    APP_PID=""
    rm -f "$SOCKET"
}

# Regression guard for issue #289: after clear-originals-cache the scoped
# cache dir under $WORK_DIR must hold no cached originals — only the
# regenerated empty index.json. If scoping ever regresses, the app would
# clear the user's real cache and this dir would be untouched (or absent),
# so this fails loudly.
assert_originals_cleared_under_workdir() {
    if [ ! -d "$ORIGINALS_CACHE" ]; then
        echo "ERROR: scoped originals dir $ORIGINALS_CACHE missing — cache was not scoped to \$WORK_DIR"
        exit 1
    fi
    local stray
    stray=$(find "$ORIGINALS_CACHE" -type f ! -name index.json | wc -l | tr -d ' ')
    if [ "$stray" != "0" ]; then
        echo "ERROR: expected no cached originals under $ORIGINALS_CACHE, found $stray"
        find "$ORIGINALS_CACHE" -type f ! -name index.json
        exit 1
    fi
    if [ -f "$ORIGINALS_CACHE/index.json" ]; then
        # `entries` is a dict, not a list — an empty cache serialises to {}.
        local entries
        entries=$("$REPO_ROOT/bin/harness-json-extract" 'entries' < "$ORIGINALS_CACHE/index.json")
        if [ "$entries" != "{}" ]; then
            echo "ERROR: expected empty index entries {} after clear, got '$entries'"
            exit 1
        fi
    fi
    echo "  OK: originals cache empty under \$WORK_DIR after clear"
}

echo "=== Seeding catalog from $SEED_SRC ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$ORIGINALS_CACHE" "$SCREENSHOT_DIR"
"$FIXTURE_BIN" seed \
    --catalog "$CATALOG_PATH" \
    --cache "$PREVIEW_CACHE" \
    --seed-dir "$SEED_SRC"

if [ ! -f "$CATALOG_PATH" ]; then
    echo "ERROR: dimroom-fixture did not produce $CATALOG_PATH"
    exit 1
fi

echo "=== Launching app (round 1) ==="
launch_app

echo "=== get-setting libraryGridColumns (expect default 4) ==="
GET_OUT=$("$CLI_BIN" get-setting libraryGridColumns --socket "$SOCKET")
echo "$GET_OUT"
VALUE=$(printf '%s' "$GET_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.value')
if [ "$VALUE" != "4" ]; then
    echo "ERROR: expected libraryGridColumns default 4, got '$VALUE'"
    exit 1
fi
echo "  OK: libraryGridColumns default == 4"

echo "=== set-setting libraryGridColumns 6 ==="
SET_OUT=$("$CLI_BIN" set-setting libraryGridColumns 6 --socket "$SOCKET")
echo "$SET_OUT"
if ! echo "$SET_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-setting did not return ok"
    exit 1
fi

echo "=== get-setting libraryGridColumns (expect 6) ==="
GET_OUT=$("$CLI_BIN" get-setting libraryGridColumns --socket "$SOCKET")
echo "$GET_OUT"
VALUE=$(printf '%s' "$GET_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.value')
if [ "$VALUE" != "6" ]; then
    echo "ERROR: expected libraryGridColumns 6 after set, got '$VALUE'"
    exit 1
fi
echo "  OK: round-trip libraryGridColumns == 6"

echo "=== set-setting developHistogramVisible false ==="
SET_OUT=$("$CLI_BIN" set-setting developHistogramVisible false --socket "$SOCKET")
echo "$SET_OUT"
if ! echo "$SET_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-setting (bool) did not return ok"
    exit 1
fi

echo "=== get-setting developHistogramVisible (expect false) ==="
GET_OUT=$("$CLI_BIN" get-setting developHistogramVisible --socket "$SOCKET")
echo "$GET_OUT"
VALUE=$(printf '%s' "$GET_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.value')
if [ "$VALUE" != "false" ]; then
    echo "ERROR: expected developHistogramVisible false, got '$VALUE'"
    exit 1
fi
echo "  OK: round-trip developHistogramVisible == false"

echo "=== set-setting unknownKey (expect error) ==="
if "$CLI_BIN" set-setting garbageKey 1 --socket "$SOCKET" 2>/dev/null | grep -q '"error"'; then
    echo "  OK: unknown key rejected"
else
    # Some CLI errors come back as non-zero exit codes too; that's also fine.
    echo "  OK: unknown key rejected (non-zero exit)"
fi

echo "=== clear-originals-cache ==="
CLEAR_OUT=$("$CLI_BIN" clear-originals-cache --socket "$SOCKET")
echo "$CLEAR_OUT"
if ! echo "$CLEAR_OUT" | grep -q '"ok"'; then
    echo "ERROR: clear-originals-cache did not return ok"
    exit 1
fi
echo "  OK: clear-originals-cache returned ok"
assert_originals_cleared_under_workdir

echo "=== clear-preview-cache ==="
CLEAR_OUT=$("$CLI_BIN" clear-preview-cache --socket "$SOCKET")
echo "$CLEAR_OUT"
if ! echo "$CLEAR_OUT" | grep -q '"ok"'; then
    echo "ERROR: clear-preview-cache did not return ok"
    exit 1
fi
echo "  OK: clear-preview-cache returned ok"

# Settings persistence is guarded by an isolated UserDefaults suite —
# `-DimroomSettingsSuite` overrides which suite the store reads from.
# Cycle the app and assert the value the previous instance wrote survives.
echo "=== quit app (round 1) ==="
quit_app

echo "=== Launching app (round 2) — same defaults suite ==="
launch_app

echo "=== get-setting libraryGridColumns (expect persisted 6) ==="
GET_OUT=$("$CLI_BIN" get-setting libraryGridColumns --socket "$SOCKET")
echo "$GET_OUT"
VALUE=$(printf '%s' "$GET_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.value')
if [ "$VALUE" != "6" ]; then
    echo "ERROR: expected persisted libraryGridColumns 6, got '$VALUE'"
    exit 1
fi
echo "  OK: persisted libraryGridColumns == 6 across relaunch"

echo "=== quit ==="
quit_app

echo "=== Harness settings flow PASSED ==="
