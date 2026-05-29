#!/usr/bin/env bash
# harness-restore-catalog-flow.sh — Layer C flow for #234 (catalog
# restore from Drive on first launch / new machine).
#
# Builds a fixture "remote" catalog with N assets, then launches the app
# pointing `--fixture-catalog` at a non-existent local path. The launch
# path detects the absent catalog, sees DIMROOM_HARNESS_STUB_REMOTE_CATALOG,
# routes through `LocalFileStubCatalogUploader` (no Google traffic), and
# auto-confirms the restore prompt via DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE
# so the modal NSAlert doesn't block headless mode.
#
# After launch:
#   1. Assert state.assetCount == N (proves the restored catalog opened)
#   2. Assert the local catalog file exists at the expected path
#   3. Send `restore-catalog-from-drive` and assert outcome=localCatalogPresent
#      (proves subsequent invocations don't re-prompt)
#   4. Quit
#
# Layer B covers the prompt's visual content; this flow covers the
# end-to-end launch wiring.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/restore-catalog}"
WORK_DIR="$REPO_ROOT/.artifacts/harness-restore-catalog"
REMOTE_CATALOG="$WORK_DIR/remote-catalog.sqlite"
REMOTE_PREVIEW_CACHE="$WORK_DIR/remote-previews"
LOCAL_CATALOG="$WORK_DIR/local/catalog.sqlite"
LOCAL_PREVIEW_CACHE="$WORK_DIR/local-previews"
# Scope the originals staging dir + LRU originals cache under $WORK_DIR so
# any originals fetch writes its downloads + index.json here, never into the
# user's real ~/Library/Application Support/Dimroom/originals (issue #331).
ORIGINALS_CACHE="$WORK_DIR/originals"
SOCKET="/tmp/dimroom-harness-restore-catalog-$$.sock"
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

echo "=== Seeding remote fixture catalog ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$ORIGINALS_CACHE"
mkdir -p "$SCREENSHOT_DIR"

"$FIXTURE_BIN" seed \
    --catalog "$REMOTE_CATALOG" \
    --cache "$REMOTE_PREVIEW_CACHE" \
    --seed-dir "$REPO_ROOT/fixtures/library-seed"

if [ ! -f "$REMOTE_CATALOG" ]; then
    echo "ERROR: dimroom-fixture did not produce $REMOTE_CATALOG"
    exit 1
fi

# Sidecar so the stub uploader can answer the prompt's photo count
# without opening SQLite.
EXPECTED_COUNT=3
printf '{"photoCount":%s}\n' "$EXPECTED_COUNT" > "$REMOTE_CATALOG.json"

# Sanity: local path should NOT exist yet so the restore branch fires.
if [ -f "$LOCAL_CATALOG" ]; then
    echo "ERROR: local catalog $LOCAL_CATALOG already exists; the restore branch wouldn't fire"
    exit 1
fi

echo "=== Launching app in harness mode with stub remote catalog ==="
# `_AT_LAUNCH` (#283) opts this flow into the launch-time restore
# path. Without it, the launch decision would route to
# `.offerConnectNoAuth` and defer restore to the post-connect sink —
# which is what the new in-session flow exercises.
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_HARNESS_DRIVE_STUB=1 \
DIMROOM_HARNESS_STUB_REMOTE_CATALOG="$REMOTE_CATALOG" \
DIMROOM_HARNESS_STUB_REMOTE_CATALOG_AT_LAUNCH=1 \
DIMROOM_HARNESS_STUB_REMOTE_CATALOG_PHOTO_COUNT="$EXPECTED_COUNT" \
DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=1 \
DIMROOM_ORIGINALS_DIR="$ORIGINALS_CACHE" \
    "$APP_BIN" --harness \
    --fixture-catalog "$LOCAL_CATALOG" \
    --preview-cache "$LOCAL_PREVIEW_CACHE" \
    --originals-cache "$ORIGINALS_CACHE" &
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

echo "=== Asserting local catalog file was created by the launch-time restore ==="
if [ ! -f "$LOCAL_CATALOG" ]; then
    echo "ERROR: local catalog $LOCAL_CATALOG not created by restore"
    exit 1
fi
echo "  OK: local catalog present at $LOCAL_CATALOG"

echo "=== state — assert restored asset count ==="
STATE_OUT=$("$CLI_BIN" state --socket "$SOCKET")
echo "$STATE_OUT"
STATE_COUNT=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.assetCount')
if [ "$STATE_COUNT" != "$EXPECTED_COUNT" ]; then
    echo "ERROR: expected assetCount=$EXPECTED_COUNT after restore, got '$STATE_COUNT'"
    exit 1
fi
echo "  OK: state reports $STATE_COUNT assets after restore"

take_screenshot "restore-catalog-after-launch"

echo "=== restore-catalog-from-drive — assert subsequent invocation reports localCatalogPresent ==="
RESTORE_OUT=$("$CLI_BIN" restore-catalog-from-drive --socket "$SOCKET")
echo "$RESTORE_OUT"
RESTORE_OUTCOME=$(printf '%s' "$RESTORE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.outcome')
if [ "$RESTORE_OUTCOME" != "localCatalogPresent" ]; then
    echo "ERROR: expected outcome=localCatalogPresent on second invocation, got '$RESTORE_OUTCOME'"
    exit 1
fi
echo "  OK: outcome=localCatalogPresent — subsequent launches don't re-prompt"

echo "=== restore-catalog-from-drive --decline — same outcome, but covers the flag wiring ==="
DECLINE_OUT=$("$CLI_BIN" restore-catalog-from-drive --decline --socket "$SOCKET")
echo "$DECLINE_OUT"
DECLINE_OUTCOME=$(printf '%s' "$DECLINE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.outcome')
# Local file is still present, so outcome must remain localCatalogPresent
# regardless of confirm/decline — the prompt never fires.
if [ "$DECLINE_OUTCOME" != "localCatalogPresent" ]; then
    echo "ERROR: expected localCatalogPresent on declined re-run, got '$DECLINE_OUTCOME'"
    exit 1
fi

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness restore-catalog flow PASSED ==="
