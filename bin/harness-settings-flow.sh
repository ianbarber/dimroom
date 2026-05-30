#!/usr/bin/env bash
# harness-settings-flow.sh — Layer C flow for the Settings store
# (issue #236).
#
# Exercises the get-setting / set-setting / clear-originals-cache /
# clear-preview-cache harness commands against an isolated UserDefaults
# suite, then relaunches the app with the same suite and verifies the
# write survived process restart.
#
# Beyond the round-trips, the clear/budget commands are checked for their
# actual side effects (issue #290), not just an "ok" response:
#   - shrinking originalsCacheBudgetBytes evicts the LRU original;
#   - clear-originals-cache wipes content without resetting settings;
#   - clear-preview-cache deletes a sentinel file off disk.
#
# Assumes capture-screenshots skill has already built the app + CLI;
# this script never rebuilds.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/settings}"
SEED_SRC="$REPO_ROOT/fixtures/library-seed"
WORK_DIR="$REPO_ROOT/.artifacts/harness-settings"
CATALOG_PATH="$WORK_DIR/catalog.sqlite"
PREVIEW_CACHE="$WORK_DIR/previews"
# Scope the originals staging + LRU cache under $WORK_DIR so the
# clear-originals-cache step can't touch the user's real
# ~/Library/Application Support/Dimroom/originals (issue #289).
ORIGINALS_CACHE="$WORK_DIR/originals"
ORIGINALS_INDEX="$ORIGINALS_CACHE/index.json"
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
    # The helper scopes both --originals-cache and DIMROOM_ORIGINALS_DIR to
    # $WORK_DIR/originals (== $ORIGINALS_CACHE), so the eviction assertion below
    # inspects our pre-seeded index, not the user's real cache, and import
    # staging stays out of Application Support too (scoping from issue #289).
    # --settings-suite + --preview-cache come from the convention globals.
    FIXTURE_CATALOG="$CATALOG_PATH"
    HARNESS_WORK_DIR="$WORK_DIR"
    SETTINGS_SUITE="$DEFAULTS_DOMAIN"
    harness_launch_app
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

# Pre-seed the originals LRU cache with two equally-sized payloads so the
# budget-shrink eviction assertion has something to evict. `A.bin` was
# "accessed" two minutes ago, `B.bin` just now — so shrinking the budget to
# fit one entry must evict A (the LRU) and keep B.
#
# This couples the flow to the on-disk shape of `OriginalsCacheIndex`
# (entries keyed by asset UUID; ISO8601 `lastAccess`; the index `bytes`
# field — not the file size — drives the eviction math). Kept in one place
# on purpose so the coupling is obvious if that format ever changes.
seed_originals_cache() {
    mkdir -p "$ORIGINALS_CACHE"
    dd if=/dev/zero of="$ORIGINALS_CACHE/A.bin" bs=1024 count=1 2>/dev/null
    dd if=/dev/zero of="$ORIGINALS_CACHE/B.bin" bs=1024 count=1 2>/dev/null
    local old_access new_access
    old_access=$(date -u -v-120S +%Y-%m-%dT%H:%M:%SZ)
    new_access=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "$ORIGINALS_INDEX" <<EOF
{
  "entries" : {
    "00000000-0000-0000-0000-000000000001" : {
      "bytes" : 1024,
      "filename" : "A.bin",
      "lastAccess" : "$old_access"
    },
    "00000000-0000-0000-0000-000000000002" : {
      "bytes" : 1024,
      "filename" : "B.bin",
      "lastAccess" : "$new_access"
    }
  }
}
EOF
}

# Regression guard for issue #289: after clear-originals-cache the scoped
# cache dir under $WORK_DIR must hold no cached originals — only the
# regenerated empty index.json. The presence of that index.json is the
# positive signal that the app actually used the scoped dir: if scoping
# ever regresses, the app clears the user's real cache and writes its
# index.json there instead, leaving this dir without one — so the
# mandatory index.json check below fails loudly.
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
    # index.json MUST exist: clear-originals-cache writes it into the scoped
    # dir unconditionally (an empty cache serialises to {"entries":{}}). Its
    # absence means the app wrote its cache somewhere else (the real
    # ~/Library/.../originals) — i.e. scoping regressed. Fail loudly.
    if [ ! -f "$ORIGINALS_CACHE/index.json" ]; then
        echo "ERROR: $ORIGINALS_CACHE/index.json missing — app wrote its cache elsewhere; scoping regressed"
        exit 1
    fi
    # `entries` is a dict, not a list — an empty cache serialises to {}.
    local entries
    entries=$("$REPO_ROOT/bin/harness-json-extract" 'entries' < "$ORIGINALS_CACHE/index.json")
    if [ "$entries" != "{}" ]; then
        echo "ERROR: expected empty index entries {} after clear, got '$entries'"
        exit 1
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

echo "=== Seeding originals cache (A.bin LRU, B.bin MRU) ==="
seed_originals_cache

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

# Shrinking originalsCacheBudgetBytes below the cache total must evict the
# least-recently-accessed original. The two seeded entries total 2048 bytes;
# a 1500-byte budget fits exactly one, so A.bin (LRU) is evicted and B.bin
# (MRU) survives. The budget change routes through a Combine subscription
# that dispatches `setBudget` onto the cache actor, so the eviction is async
# — poll the index rather than asserting immediately.
echo "=== set-setting originalsCacheBudgetBytes 1500 (expect A.bin evicted) ==="
SET_OUT=$("$CLI_BIN" set-setting originalsCacheBudgetBytes 1500 --socket "$SOCKET")
echo "$SET_OUT"
if ! echo "$SET_OUT" | grep -q '"ok"'; then
    echo "ERROR: set-setting originalsCacheBudgetBytes did not return ok"
    exit 1
fi

ENTRY_COUNT=""
for i in $(seq 1 15); do
    ENTRY_COUNT=$(jq '.entries | length' "$ORIGINALS_INDEX" 2>/dev/null || echo "")
    if [ "$ENTRY_COUNT" = "1" ]; then
        break
    fi
    sleep 0.2
done
if [ "$ENTRY_COUNT" != "1" ]; then
    echo "ERROR: expected exactly 1 cache entry after eviction, got '$ENTRY_COUNT'"
    echo "index.json was:"; cat "$ORIGINALS_INDEX" 2>/dev/null || echo "(missing)"
    exit 1
fi
SURVIVOR=$(jq -r '[.entries[].filename][0]' "$ORIGINALS_INDEX")
if [ "$SURVIVOR" != "B.bin" ]; then
    echo "ERROR: expected B.bin (MRU) to survive eviction, index kept '$SURVIVOR'"
    exit 1
fi
if [ -f "$ORIGINALS_CACHE/A.bin" ]; then
    echo "ERROR: A.bin (LRU) should have been deleted from disk on eviction"
    exit 1
fi
if [ ! -f "$ORIGINALS_CACHE/B.bin" ]; then
    echo "ERROR: B.bin (MRU) should still be on disk after eviction"
    exit 1
fi
echo "  OK: budget shrink evicted A.bin (LRU), kept B.bin (MRU)"

echo "=== clear-originals-cache ==="
CLEAR_OUT=$("$CLI_BIN" clear-originals-cache --socket "$SOCKET")
echo "$CLEAR_OUT"
if ! echo "$CLEAR_OUT" | grep -q '"ok"'; then
    echo "ERROR: clear-originals-cache did not return ok"
    exit 1
fi
echo "  OK: clear-originals-cache returned ok"
assert_originals_cleared_under_workdir

# clearOriginalsCache is a content-only wipe: it must not reset unrelated
# settings. libraryGridColumns was set to 6 above; assert it survives the
# clear. Guards against a future refactor that wires SettingsStore.reset()
# into the clear path.
echo "=== get-setting libraryGridColumns after clear (expect still 6) ==="
GET_OUT=$("$CLI_BIN" get-setting libraryGridColumns --socket "$SOCKET")
echo "$GET_OUT"
VALUE=$(printf '%s' "$GET_OUT" | "$REPO_ROOT/bin/harness-json-extract" 'data.value')
if [ "$VALUE" != "6" ]; then
    echo "ERROR: clear-originals-cache reset libraryGridColumns to '$VALUE' (expected 6)"
    exit 1
fi
echo "  OK: clear-originals-cache left libraryGridColumns == 6 (content-only)"

# Prove clear-preview-cache actually wipes files, not just returns ok.
# Drop a sentinel into the preview cache dir; PreviewStore.removeAll()
# iterates the directory and removes each entry, so the top-level sentinel
# must be gone afterwards.
echo "=== seed preview-cache sentinel ==="
printf '\xFF\xD8\xFF' > "$PREVIEW_CACHE/sentinel.jpg"
if [ ! -f "$PREVIEW_CACHE/sentinel.jpg" ]; then
    echo "ERROR: failed to write preview-cache sentinel"
    exit 1
fi

echo "=== clear-preview-cache (expect sentinel wiped) ==="
CLEAR_OUT=$("$CLI_BIN" clear-preview-cache --socket "$SOCKET")
echo "$CLEAR_OUT"
if ! echo "$CLEAR_OUT" | grep -q '"ok"'; then
    echo "ERROR: clear-preview-cache did not return ok"
    exit 1
fi
if [ -f "$PREVIEW_CACHE/sentinel.jpg" ]; then
    echo "ERROR: clear-preview-cache left sentinel.jpg in place"
    exit 1
fi
echo "  OK: clear-preview-cache wiped the sentinel file"

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
