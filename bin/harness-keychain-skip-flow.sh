#!/usr/bin/env bash
# harness-keychain-skip-flow.sh — Layer C flow for the harness Keychain bypass (#260).
#
# Repro context: SPM debug builds re-sign the binary on every rebuild,
# which invalidates the Keychain item ACL bound to the previous
# signature. Before #260, a `--harness` launch with a configured
# `DIMROOM_GOOGLE_CLIENT_ID` would call `KeychainTokenStore.load`
# during DriveAuthState hydration on launch, popping a password
# dialog. The fix is to swap the token store for `InMemoryTokenStore`
# whenever `--harness` is in args, regardless of OAuth config.
#
# This flow exercises the exact path that used to trip the prompt:
#   - real OAuth config present (DIMROOM_GOOGLE_CLIENT_ID=test-client-id)
#   - --harness flag set
#   - no DIMROOM_HARNESS_DRIVE_STUB (so we take the production
#     `OAuthConfig.load()` branch, not the stub-client shortcut)
#
# It asserts the `drive-auth-state` payload exposes
# `tokenStoreKind == "in-memory"` and `configured == true`, which only
# holds if the Keychain branch was skipped.
#
# Assumes the capture-screenshots skill / harness-smoke build pipeline
# has already produced the App and CLI binaries.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/keychain-skip}"
WORK_DIR="$REPO_ROOT/.artifacts/harness-keychain-skip"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
SOCKET="/tmp/dimroom-harness-keychain-skip-$$.sock"
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

echo "=== Launching app in harness mode with real-OAuth-config path ==="
# Important: DIMROOM_GOOGLE_CLIENT_ID is set (so OAuthConfig.load()
# succeeds and the `DriveClient` is built), but DIMROOM_HARNESS_DRIVE_STUB
# is intentionally NOT set — this is the path that used to construct a
# `KeychainTokenStore` and prompt for the password on every rebuild.
# We also unset DIMROOM_HARNESS_DRIVE_STUB defensively in case the
# parent shell has it.
unset DIMROOM_HARNESS_DRIVE_STUB
DIMROOM_HARNESS_SOCKET="$SOCKET" \
DIMROOM_GOOGLE_CLIENT_ID="test-client-id" \
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

echo "=== drive-auth-state — assert in-memory token store and no Keychain ==="
STATE_OUT=$("$CLI_BIN" drive-auth-state --socket "$SOCKET")
echo "$STATE_OUT"

KIND=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.tokenStoreKind')
CONFIGURED=$(printf '%s' "$STATE_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.configured')

if [ "$KIND" != "in-memory" ]; then
    echo "ERROR: expected tokenStoreKind 'in-memory' under --harness with OAuth config, got '$KIND'"
    echo "ERROR: this means the launch path is still constructing KeychainTokenStore — the Keychain prompt regression has returned"
    exit 1
fi
echo "  OK: tokenStoreKind = in-memory (Keychain skipped)"

# `configured == true` proves the OAuth config branch was taken (i.e.
# `OAuthConfig.load()` did succeed with DIMROOM_GOOGLE_CLIENT_ID) — the
# DriveClient was built. If we instead got `configured == false`, the
# launch would have returned a `nil` DriveClient and the assertion
# above would be meaningless: any harness run trivially "skips the
# Keychain" by not constructing a DriveClient at all. We want to prove
# the skip happens specifically on the OAuth-configured path.
if [ "$CONFIGURED" != "true" ]; then
    echo "ERROR: expected configured = true (real DriveClient built), got '$CONFIGURED'"
    echo "ERROR: the assertion is only meaningful when a real OAuth config is present"
    exit 1
fi
echo "  OK: configured = true (real DriveClient wired)"

echo "=== quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true

sleep 1
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "WARN: App did not exit after quit, killing"
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness keychain-skip flow PASSED ==="
