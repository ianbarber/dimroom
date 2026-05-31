#!/usr/bin/env bash
# harness-originals-isolation-check.sh — regression guard for #331 (follow-up
# to #289).
#
# Proves that running the harness flow scripts never writes cached originals
# or index.json into the user's REAL originals cache at
#   ~/Library/Application Support/Dimroom/originals
# Every flow is supposed to point DIMROOM_ORIGINALS_DIR + --originals-cache at
# a branch-scoped .artifacts path; if one regresses (or grows a real originals
# fetch without scoping), the app writes into Application Support and this
# guard catches it.
#
# How it works:
#   1. Snapshot a manifest (relative path + size) of the real originals dir.
#   2. Drop a single sentinel file there. The sentinel does double duty: it
#      proves the check is watching the right directory, and it detects a
#      destructive wipe (a flow that erroneously ran clear-originals-cache
#      against the real dir would delete it).
#   3. Run the flows with DIMROOM_ORIGINALS_DIR UNSET in the environment — so a
#      flow that forgot to scope its own launch genuinely falls back to the
#      real dir and gets caught, rather than inheriting our scoping and hiding
#      the leak.
#   4. Re-snapshot and FAIL if the manifest changed (a new original / index.json
#      appeared, or an existing file changed) or the sentinel was disturbed.
#
# Non-destructive: it never runs clear-originals-cache and never deletes the
# user's cached files. On exit it removes only its own sentinel, and removes
# the originals dir only if this script created it AND it is still empty.
#
# Two modes:
#
#   * Flow-sweep (default) — LOCAL/MANUAL, deliberately NOT wired into CI.
#     Runs the real harness flow scripts with DIMROOM_ORIGINALS_DIR unset to
#     catch any flow that forgot to scope its own launch. It drives many GUI
#     launches and is slow, so it stays a dev-machine tool:
#       bin/harness-originals-isolation-check.sh                 # default flow set
#       bin/harness-originals-isolation-check.sh FLOW [FLOW...]  # explicit flows
#       bin/harness-originals-isolation-check.sh --all           # every harness-*.sh flow
#
#   * --default-launch — CI-ENROLLED focused guard (Layer C for #367). Launches
#     the app ONCE in --harness mode with the originals knobs *omitted*
#     (DIMROOM_ORIGINALS_DIR unset, no --originals-cache) against a seeded
#     fixture catalog, then asserts (a) the app's resolved `originals dir = …`
#     landed in the temp sandbox and (b) the real originals dir is untouched.
#     This exercises #367's app-level default, which the shared
#     bin/lib/harness-launch.sh helper can't (it always scopes the knobs):
#       bin/harness-originals-isolation-check.sh --default-launch
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=lib/originals-isolation.sh
. "$REPO_ROOT/bin/lib/originals-isolation.sh"
# Sourced for harness_wait_for_socket in --default-launch mode. We do NOT use
# harness_launch_app: it always sets DIMROOM_ORIGINALS_DIR + --originals-cache,
# which is exactly the scoping --default-launch must omit.
# shellcheck source=lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"

# The app resolves its originals dir to Application Support unless
# DIMROOM_ORIGINALS_DIR / --originals-cache override it (see
# resolveOriginalsDirectory in App/Sources/DimroomApp.swift). This is that
# real, unscoped location — the one no flow may touch.
REAL_ORIGINALS="$HOME/Library/Application Support/Dimroom/originals"
SENTINEL_NAME="__isolation-sentinel__"
SENTINEL="$REAL_ORIGINALS/$SENTINEL_NAME"
SENTINEL_CONTENT="dimroom originals-isolation sentinel (#331) — safe to delete"

BEFORE_MANIFEST="$(mktemp -t dimroom-originals-before)"
AFTER_MANIFEST="$(mktemp -t dimroom-originals-after)"
CREATED_REAL_DIR=0

# --default-launch mode bookkeeping (stay empty in flow-sweep mode).
DEFAULT_LAUNCH_APP_PID=""
DEFAULT_LAUNCH_SOCKET=""

cleanup() {
    # --default-launch leftovers: stop the app and remove its socket.
    if [ -n "$DEFAULT_LAUNCH_APP_PID" ] && kill -0 "$DEFAULT_LAUNCH_APP_PID" 2>/dev/null; then
        kill "$DEFAULT_LAUNCH_APP_PID" 2>/dev/null || true
        wait "$DEFAULT_LAUNCH_APP_PID" 2>/dev/null || true
    fi
    [ -n "$DEFAULT_LAUNCH_SOCKET" ] && rm -f "$DEFAULT_LAUNCH_SOCKET" 2>/dev/null || true
    rm -f "$SENTINEL" 2>/dev/null || true
    # If we created the real dir solely to host the sentinel and nothing else
    # landed in it, restore the prior state by removing the now-empty dir.
    # Never rmdir a dir that holds other files (e.g. a real leak we just
    # reported) — leave that evidence in place for inspection.
    if [ "$CREATED_REAL_DIR" = "1" ] && [ -d "$REAL_ORIGINALS" ]; then
        rmdir "$REAL_ORIGINALS" 2>/dev/null || true
    fi
    rm -f "$BEFORE_MANIFEST" "$AFTER_MANIFEST" 2>/dev/null || true
}
trap cleanup EXIT

# Print "<size> <relpath>" for every file under the real dir except our own
# sentinel, sorted for a stable comparison. macOS BSD stat (-f) — this repo is
# macOS-only. Empty output when the dir is absent.
snapshot_manifest() {
    local out="$1"
    if [ -d "$REAL_ORIGINALS" ]; then
        ( cd "$REAL_ORIGINALS" \
            && find . -type f ! -name "$SENTINEL_NAME" -exec stat -f '%z %N' {} \; ) \
            | sort > "$out"
    else
        : > "$out"
    fi
}

# --default-launch: the CI-enrolled focused guard. Launch the app once with
# the originals knobs omitted and prove #367's app-level isolation end to end:
#   (a) the resolved `originals dir = …` line lands in the temp sandbox, and
#   (b) the real App Support originals dir is byte-for-byte untouched.
# Reuses the shared sentinel + snapshot_manifest machinery above and
# harness_wait_for_socket from bin/lib/harness-launch.sh. Returns 0 on pass.
run_default_launch_check() {
    local work_dir="$REPO_ROOT/.artifacts/harness-originals-isolation"
    local catalog="$work_dir/catalog.sqlite"
    local preview_cache="$work_dir/previews"
    local screenshot_dir="${SCREENSHOT_DIR:-$REPO_ROOT/.artifacts/originals-isolation}"
    local socket="/tmp/dimroom-harness-originals-isolation-$$.sock"
    local log="$work_dir/launch.log"
    local app_bin="$REPO_ROOT/App/.build/debug/Dimroom"
    local cli_bin="$REPO_ROOT/Packages/Harness/.build/debug/dimroom-cli"
    local fixture_bin="$REPO_ROOT/Packages/Harness/.build/debug/dimroom-fixture"

    DEFAULT_LAUNCH_SOCKET="$socket"

    # 1. Seed a throwaway fixture catalog (same seed the library flow uses).
    echo "=== Seeding fixture catalog: $catalog ==="
    rm -rf "$work_dir"
    mkdir -p "$work_dir" "$screenshot_dir"
    "$fixture_bin" seed \
        --catalog "$catalog" \
        --cache "$preview_cache" \
        --seed-dir "$REPO_ROOT/fixtures/library-seed"
    if [ ! -f "$catalog" ]; then
        echo "FAIL: dimroom-fixture did not produce $catalog"
        return 1
    fi

    # 2. Baseline the real originals dir + drop the sentinel (shared machinery).
    echo "=== Snapshotting real originals dir: $REAL_ORIGINALS ==="
    if [ -d "$REAL_ORIGINALS" ]; then
        echo "  dir exists — recording manifest"
    else
        echo "  dir absent — creating it just to host the sentinel (removed on exit)"
        mkdir -p "$REAL_ORIGINALS"
        CREATED_REAL_DIR=1
    fi
    snapshot_manifest "$BEFORE_MANIFEST"
    BEFORE_COUNT=$(wc -l < "$BEFORE_MANIFEST" | tr -d ' ')
    echo "  baseline: $BEFORE_COUNT file(s) (excluding sentinel)"
    printf '%s\n' "$SENTINEL_CONTENT" > "$SENTINEL"

    # 3. Launch the app with the originals knobs OMITTED. DIMROOM_ORIGINALS_DIR
    #    is force-unset (env -u) so an inherited value can't mask the default,
    #    and --originals-cache is simply not passed — this is the un-scoped
    #    launch the shared harness-launch helper deliberately cannot do.
    echo "=== Launching app in --harness mode with originals knobs omitted ==="
    env -u DIMROOM_ORIGINALS_DIR \
        DIMROOM_HARNESS_SOCKET="$socket" \
        DIMROOM_HARNESS_DISABLE_DRIVE=1 \
        DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0 \
        "$app_bin" --harness \
        --fixture-catalog "$catalog" \
        --preview-cache "$preview_cache" \
        > "$log" 2>&1 &
    DEFAULT_LAUNCH_APP_PID=$!

    if ! harness_wait_for_socket "$socket" "$DEFAULT_LAUNCH_APP_PID" 30; then
        echo "FAIL: app did not come up on the control socket"
        echo "----- launch log -----"; cat "$log" 2>/dev/null || true; echo "----------------------"
        return 1
    fi

    # 4. Screenshot for PR artifact parity (best-effort, never fatal).
    "$cli_bin" screenshot "$screenshot_dir/originals-isolation.png" \
        --socket "$socket" >/dev/null 2>&1 || true

    # 5. Quit cleanly — this FLUSHES the buffered launch stdout so the
    #    `originals dir = …` line is reliably present (known flush gotcha:
    #    a kill leaves the buffer unwritten).
    echo "=== Quitting app to flush the launch log ==="
    "$cli_bin" quit --socket "$socket" >/dev/null 2>&1 || true
    if [ -n "$DEFAULT_LAUNCH_APP_PID" ]; then
        wait "$DEFAULT_LAUNCH_APP_PID" 2>/dev/null || true
        DEFAULT_LAUNCH_APP_PID=""
    fi

    local status=0

    # 6. Assertion (a): the resolved originals dir landed in the temp sandbox.
    #    Non-empty also proves the launch happened and logged (non-vacuous).
    local resolved
    resolved="$(grep -E 'originals dir = ' "$log" | sed -E 's/.*originals dir = //' | tail -n 1)"
    if [ -z "$resolved" ]; then
        echo "FAIL: no 'originals dir = …' line in the launch log — check was vacuous"
        echo "----- launch log -----"; cat "$log" 2>/dev/null || true; echo "----------------------"
        status=1
    elif originals_path_is_isolated "$resolved" "$REAL_ORIGINALS"; then
        echo "  OK: resolved originals dir is in the temp sandbox: $resolved"
    else
        echo "FAIL: resolved originals dir is NOT isolated: $resolved"
        echo "      expected a path under …/$ORIGINALS_ISOLATION_NAMESPACE/ and outside $REAL_ORIGINALS"
        status=1
    fi

    # 7. Assertion (b): the real App Support originals dir is untouched.
    echo "=== Re-snapshotting real originals dir ==="
    snapshot_manifest "$AFTER_MANIFEST"
    if ! diff -u "$BEFORE_MANIFEST" "$AFTER_MANIFEST" > "/tmp/dimroom-originals-diff.$$" 2>&1; then
        echo "FAIL: real originals dir changed — the launched app leaked into $REAL_ORIGINALS"
        echo "      (- = before, + = after; '<size> <relpath>')"
        sed 's/^/      /' "/tmp/dimroom-originals-diff.$$"
        status=1
    else
        echo "  OK: manifest unchanged ($BEFORE_COUNT file(s))"
    fi
    rm -f "/tmp/dimroom-originals-diff.$$" 2>/dev/null || true
    if [ ! -f "$SENTINEL" ]; then
        echo "FAIL: sentinel gone — the app wiped $REAL_ORIGINALS"
        status=1
    elif [ "$(cat "$SENTINEL")" != "$SENTINEL_CONTENT" ]; then
        echo "FAIL: sentinel content changed — the real originals dir was disturbed"
        status=1
    else
        echo "  OK: sentinel intact"
    fi

    if [ "$status" -eq 0 ]; then
        echo "=== Originals isolation (--default-launch) PASSED — app stayed out of $REAL_ORIGINALS ==="
    else
        echo "=== Originals isolation (--default-launch) FAILED ==="
    fi
    return "$status"
}

# Mode dispatch: the CI-enrolled focused guard builds the binaries it needs,
# runs the single-launch check, and exits — never falling through to the
# local flow-sweep path below.
if [ "${1:-}" = "--default-launch" ]; then
    echo "=== Building App + harness binaries (so the launch doesn't have to) ==="
    swift build --package-path "$REPO_ROOT/App"
    swift build --package-path "$REPO_ROOT/Packages/Harness" --product dimroom-cli
    swift build --package-path "$REPO_ROOT/Packages/Harness" --product dimroom-fixture
    if run_default_launch_check; then
        exit 0
    else
        exit 1
    fi
fi

# Resolve the flow list.
flows=()
if [ "$#" -eq 0 ]; then
    # Default: the fetch-capable candidates called out in #331 — the develop
    # flows (open assets in Develop), the restore-catalog flows (download a
    # remote catalog), and delta-sync. These are CI-gated and reliable.
    for f in "$REPO_ROOT"/bin/harness-develop*.sh \
             "$REPO_ROOT"/bin/harness-restore-catalog*.sh \
             "$REPO_ROOT"/bin/harness-delta-sync-flow.sh; do
        [ -e "$f" ] && flows+=("$(basename "$f")")
    done
elif [ "$1" = "--all" ]; then
    for f in "$REPO_ROOT"/bin/harness-*.sh; do
        local_base="$(basename "$f")"
        [ "$local_base" = "$(basename "$0")" ] && continue  # skip self
        flows+=("$local_base")
    done
else
    flows=("$@")
fi

if [ "${#flows[@]}" -eq 0 ]; then
    echo "ERROR: no flows resolved to run"
    exit 1
fi

echo "=== Building App + harness binaries (so flows don't have to) ==="
swift build --package-path "$REPO_ROOT/App"
swift build --package-path "$REPO_ROOT/Packages/Harness" --product dimroom-cli
swift build --package-path "$REPO_ROOT/Packages/Harness" --product dimroom-fixture

echo "=== Snapshotting real originals dir: $REAL_ORIGINALS ==="
if [ -d "$REAL_ORIGINALS" ]; then
    echo "  dir exists — recording manifest"
else
    echo "  dir absent — creating it just to host the sentinel (will be removed on exit)"
    mkdir -p "$REAL_ORIGINALS"
    CREATED_REAL_DIR=1
fi
snapshot_manifest "$BEFORE_MANIFEST"
BEFORE_COUNT=$(wc -l < "$BEFORE_MANIFEST" | tr -d ' ')
echo "  baseline: $BEFORE_COUNT file(s) (excluding sentinel)"

echo "=== Seeding sentinel: $SENTINEL ==="
printf '%s\n' "$SENTINEL_CONTENT" > "$SENTINEL"

echo "=== Running ${#flows[@]} flow(s) with DIMROOM_ORIGINALS_DIR unset ==="
ran=0
failed_flows=()
for flow in "${flows[@]}"; do
    script="$REPO_ROOT/bin/$flow"
    if [ ! -f "$script" ]; then
        echo "WARN: $flow not found — skipping"
        failed_flows+=("$flow (missing)")
        continue
    fi
    echo "--- $flow ---"
    # Unset DIMROOM_ORIGINALS_DIR for the child so an unscoped flow can't
    # silently inherit our shell's value and mask the leak. Each flow sets its
    # own scoped value inline for its app launch; this only affects flows that
    # forgot to.
    if ( unset DIMROOM_ORIGINALS_DIR; bash "$script" ); then
        ran=$((ran + 1))
        echo "    OK: $flow"
    else
        rc=$?
        echo "WARN: $flow exited rc=$rc — isolation is still checked below"
        failed_flows+=("$flow (rc=$rc)")
    fi
done

echo "=== Re-snapshotting real originals dir ==="
snapshot_manifest "$AFTER_MANIFEST"

status=0

# 1. Manifest must be byte-for-byte identical.
if ! diff -u "$BEFORE_MANIFEST" "$AFTER_MANIFEST" > /tmp/dimroom-originals-diff.$$ 2>&1; then
    echo "FAIL: real originals dir changed while flows ran — a flow leaked into $REAL_ORIGINALS"
    echo "      (- = before, + = after; '<size> <relpath>')"
    sed 's/^/      /' /tmp/dimroom-originals-diff.$$
    status=1
else
    echo "  OK: manifest unchanged ($BEFORE_COUNT file(s))"
fi
rm -f /tmp/dimroom-originals-diff.$$ 2>/dev/null || true

# 2. Sentinel must be intact (proves we watched the right dir; a destructive
#    wipe would have removed it).
if [ ! -f "$SENTINEL" ]; then
    echo "FAIL: sentinel gone — a flow wiped $REAL_ORIGINALS (destructive clear leaked to the real dir)"
    status=1
elif [ "$(cat "$SENTINEL")" != "$SENTINEL_CONTENT" ]; then
    echo "FAIL: sentinel content changed — the real originals dir was disturbed"
    status=1
else
    echo "  OK: sentinel intact"
fi

# 3. The check is vacuous if no flow actually ran.
if [ "$ran" -eq 0 ]; then
    echo "FAIL: no flow ran successfully — isolation check was vacuous"
    status=1
else
    echo "  OK: $ran flow(s) ran"
fi

if [ "${#failed_flows[@]}" -gt 0 ]; then
    echo "NOTE: ${#failed_flows[@]} flow(s) did not exit cleanly: ${failed_flows[*]}"
fi

if [ "$status" -eq 0 ]; then
    echo "=== Originals isolation check PASSED — no flow touched $REAL_ORIGINALS ==="
else
    echo "=== Originals isolation check FAILED ==="
fi
exit "$status"
