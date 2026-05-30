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
# Local/manual guard — deliberately NOT wired into CI (it drives the real GUI
# app and touches a user-domain path). Run it on a dev machine:
#   bin/harness-originals-isolation-check.sh                 # default flow set
#   bin/harness-originals-isolation-check.sh FLOW [FLOW...]  # explicit flows
#   bin/harness-originals-isolation-check.sh --all           # every harness-*.sh flow
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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

cleanup() {
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
