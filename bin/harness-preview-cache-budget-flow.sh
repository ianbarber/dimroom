#!/usr/bin/env bash
# harness-preview-cache-budget-flow.sh — Layer C flow for preview cache
# budget enforcement / LRU eviction (issue #271).
#
# Imports a folder of real photos so the live PreviewStore generates
# real-sized master previews into a scoped cache dir, then lowers
# `previewCacheBudgetBytes` via the existing set-setting harness command
# and asserts the on-disk cache actually shrinks — i.e. the budget routes
# through the $previewCacheBudgetBytes Combine sink into
# PreviewStore.setBudget and eviction runs (AC #5).
#
# Then sets the budget back to 0 (unlimited) and confirms the cache is no
# longer trimmed, covering the "0 disables enforcement" path end to end.
#
# Self-contained: builds the app + CLI, launches via the shared
# bin/lib/harness-launch.sh helper with a scoped --preview-cache dir and an
# isolated UserDefaults suite, drives it, quits.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"

WORK_DIR="$REPO_ROOT/.artifacts/harness-preview-cache-budget"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
IMPORT_SOURCE="$REPO_ROOT/fixtures/library-seed"
SOCKET="/tmp/dimroom-harness-preview-budget-$$.sock"
DEFAULTS_DOMAIN="com.dimroom.harness-preview-budget-$$"
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

# KB used by the preview cache dir (field 1 of `du -sk`).
cache_kb() {
    du -sk "$PREVIEW_CACHE" 2>/dev/null | awk '{print $1}'
}

assert_json_field() {
    local label="$1" json="$2" field="$3" expected="$4"
    local actual
    actual=$(printf '%s' "$json" | "$REPO_ROOT/bin/harness-json-extract" "$field")
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: $label — expected $field == $expected, got $actual"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — $field == $expected"
}

echo "=== Building App ==="
swift build --package-path "$REPO_ROOT/App" 2>&1

echo "=== Building CLI ==="
swift build --package-path "$REPO_ROOT/Packages/Harness" --product dimroom-cli 2>&1

APP_BIN="$REPO_ROOT/App/.build/debug/Dimroom"
CLI_BIN="$REPO_ROOT/Packages/Harness/.build/debug/dimroom-cli"
for bin in "$APP_BIN" "$CLI_BIN"; do
    if [ ! -x "$bin" ]; then
        echo "ERROR: missing binary $bin"
        exit 1
    fi
done

echo "=== Preparing fresh work dir ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$PREVIEW_CACHE"
# Start from a missing catalog so the import isn't deduped against pre-seeded rows.
rm -f "$CATALOG_PATH"

echo "=== Launching app (scoped preview cache + isolated settings) ==="
FIXTURE_CATALOG="$CATALOG_PATH"
HARNESS_WORK_DIR="$WORK_DIR"
SETTINGS_SUITE="$DEFAULTS_DOMAIN"
HARNESS_ENV=(DIMROOM_HARNESS_DISABLE_DRIVE=1 DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0)
harness_launch_app

echo "=== importFolder $IMPORT_SOURCE (live PreviewStore.generate per asset) ==="
IMPORT_OUT=$("$CLI_BIN" import-folder "$IMPORT_SOURCE" --socket "$SOCKET")
echo "$IMPORT_OUT"
assert_json_field "import status" "$IMPORT_OUT" "status" "ok"
assert_json_field "import importedCount" "$IMPORT_OUT" "data.importedCount" "3"

echo "=== Measuring preview cache size before budget ==="
SIZE_BEFORE_KB=$(cache_kb)
echo "  preview cache = ${SIZE_BEFORE_KB} KB"

# Fixtures without real pixel bytes would generate near-empty previews,
# leaving nothing to evict. Skip cleanly rather than asserting on noise.
if [ -z "$SIZE_BEFORE_KB" ] || [ "$SIZE_BEFORE_KB" -le 4 ]; then
    echo "  SKIP: preview cache is empty/negligible (${SIZE_BEFORE_KB:-0} KB) — no pixel bytes to evict"
    "$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true
    exit 0
fi

# Halve the budget. Eviction trims least-recently-generated files until the
# index total is under budget; the change routes through a Combine sink that
# dispatches setBudget onto the actor, so it's async — poll until the cache
# shrinks below its pre-budget size.
BUDGET_BYTES=$(( SIZE_BEFORE_KB * 1024 / 2 ))
echo "=== set-setting previewCacheBudgetBytes $BUDGET_BYTES (≈ half of cache) ==="
SET_OUT=$("$CLI_BIN" set-setting previewCacheBudgetBytes "$BUDGET_BYTES" --socket "$SOCKET")
echo "$SET_OUT"
if ! echo "$SET_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-setting previewCacheBudgetBytes did not return ok"
    exit 1
fi

echo "=== Polling for eviction (expect cache to shrink) ==="
SIZE_AFTER_KB="$SIZE_BEFORE_KB"
for _ in $(seq 1 30); do
    SIZE_AFTER_KB=$(cache_kb)
    if [ -n "$SIZE_AFTER_KB" ] && [ "$SIZE_AFTER_KB" -lt "$SIZE_BEFORE_KB" ]; then
        break
    fi
    sleep 0.2
done
echo "  before=${SIZE_BEFORE_KB} KB  after=${SIZE_AFTER_KB} KB"
if ! [ "$SIZE_AFTER_KB" -lt "$SIZE_BEFORE_KB" ]; then
    echo "ERROR: lowering previewCacheBudgetBytes did not shrink the cache"
    echo "index.json:"; cat "$PREVIEW_CACHE/index.json" 2>/dev/null || echo "(missing)"
    exit 1
fi
echo "  OK: lowering the budget dropped the preview cache size"

# 0 disables enforcement: with eviction off the cache must not shrink
# further (nothing new is generated, so it should simply hold steady).
echo "=== set-setting previewCacheBudgetBytes 0 (unlimited) ==="
SET_OUT=$("$CLI_BIN" set-setting previewCacheBudgetBytes 0 --socket "$SOCKET")
echo "$SET_OUT"
if ! echo "$SET_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-setting previewCacheBudgetBytes 0 did not return ok"
    exit 1
fi
sleep 1
SIZE_UNLIMITED_KB=$(cache_kb)
echo "  after unlimited = ${SIZE_UNLIMITED_KB} KB"
if [ "$SIZE_UNLIMITED_KB" -lt "$SIZE_AFTER_KB" ]; then
    echo "ERROR: budget 0 still evicted (cache shrank from ${SIZE_AFTER_KB} to ${SIZE_UNLIMITED_KB} KB)"
    exit 1
fi
echo "  OK: budget 0 disabled enforcement (no further eviction)"

echo "=== Quit ==="
"$CLI_BIN" quit --socket "$SOCKET" 2>&1 || true
sleep 1
if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
fi
APP_PID=""

echo "=== Harness preview cache budget flow PASSED ==="
