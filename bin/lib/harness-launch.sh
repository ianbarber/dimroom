#!/usr/bin/env bash
# bin/lib/harness-launch.sh — shared app-launch helper for Layer C harness
# flows (#366, follow-up to #331 / #289).
#
# SOURCE this file (do not execute it). It owns the boilerplate that every
# `bin/harness-*-flow.sh` used to copy-paste: scoping originals isolation,
# launching the app in --harness mode, and blocking on the control socket.
# The headline win is that originals isolation is inherited BY DEFAULT — a
# flow no longer hand-rolls the `DIMROOM_ORIGINALS_DIR` + `--originals-cache`
# block, so it can't forget to scope (see #289's real-cache leak).
#
# Usage from a flow:
#
#     . "$REPO_ROOT/bin/lib/harness-launch.sh"
#
#     APP_BIN="$REPO_ROOT/App/.build/debug/Dimroom"
#     SOCKET="/tmp/dimroom-harness-myflow-$$.sock"
#     FIXTURE_CATALOG="$WORK_DIR/catalog.sqlite"
#     HARNESS_WORK_DIR="$WORK_DIR"          # originals default to $WORK_DIR/originals
#     # Optional, only when the flow needs them:
#     PREVIEW_CACHE="$WORK_DIR/previews"    # adds --preview-cache
#     SETTINGS_SUITE="com.dimroom.harness-myflow-$$"   # adds --settings-suite
#     HARNESS_ENV=(DIMROOM_HARNESS_DISABLE_DRIVE=1 DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE=0)
#     HARNESS_FLAGS=(--drive-backed)        # extra app argv, passed verbatim
#
#     harness_launch_app                    # sets global APP_PID, blocks on socket
#
# Conventions read from the caller's globals:
#   APP_BIN            (required) path to the Dimroom binary
#   SOCKET             (required) control socket path
#   FIXTURE_CATALOG    (required) --fixture-catalog argument
#   HARNESS_WORK_DIR   originals default to "$HARNESS_WORK_DIR/originals"
#   HARNESS_ORIGINALS_DIR   override the originals dir explicitly
#   DIMROOM_ORIGINALS_DIR   honoured if already set in the environment
#   PREVIEW_CACHE      optional --preview-cache value
#   SETTINGS_SUITE     optional --settings-suite value
#   HARNESS_ORIGINALS_CACHE   override the --originals-cache value; set to the
#                      sentinel "none" to omit --originals-cache entirely
#   HARNESS_ENV[@]     extra `VAR=value` env entries for the app process
#   HARNESS_FLAGS[@]   extra app argv appended after the standard flags
#   HARNESS_SOCKET_TIMEOUT   seconds to wait for the socket (default 30)
#
# The command/env assembly is split into pure, array-populating functions so
# it stays unit-testable (bin/tests/test-harness-launch.sh) without launching
# the GUI app.

# Populated by harness_build_env / harness_build_argv.
HARNESS_LAUNCH_ENV=()
HARNESS_LAUNCH_ARGV=()

# Echo the originals directory this launch should use. Precedence:
#   1. a pre-set DIMROOM_ORIGINALS_DIR in the environment (explicit escape hatch)
#   2. HARNESS_ORIGINALS_DIR (flow-local override)
#   3. "$HARNESS_WORK_DIR/originals" (the scoped default)
# Pure: reads globals, writes stdout, mutates nothing.
harness_resolve_originals_dir() {
    if [ -n "${DIMROOM_ORIGINALS_DIR:-}" ]; then
        printf '%s\n' "$DIMROOM_ORIGINALS_DIR"
    elif [ -n "${HARNESS_ORIGINALS_DIR:-}" ]; then
        printf '%s\n' "$HARNESS_ORIGINALS_DIR"
    else
        printf '%s\n' "${HARNESS_WORK_DIR:?harness-launch: set HARNESS_WORK_DIR or HARNESS_ORIGINALS_DIR}/originals"
    fi
}

# Populate HARNESS_LAUNCH_ENV with the env assignments for the app process:
# the control socket, the scoped originals dir, then any caller HARNESS_ENV[@].
harness_build_env() {
    local originals_dir
    originals_dir="$(harness_resolve_originals_dir)"
    HARNESS_LAUNCH_ENV=(
        "DIMROOM_HARNESS_SOCKET=$SOCKET"
        "DIMROOM_ORIGINALS_DIR=$originals_dir"
    )
    # set -u-safe append: expands to nothing when HARNESS_ENV is unset/empty.
    HARNESS_LAUNCH_ENV+=(${HARNESS_ENV[@]+"${HARNESS_ENV[@]}"})
}

# Populate HARNESS_LAUNCH_ARGV with the app argv: the always-present
# --harness / --fixture-catalog, the optional --preview-cache, the
# scoped-by-default --originals-cache, the optional --settings-suite, then
# any caller HARNESS_FLAGS[@].
harness_build_argv() {
    HARNESS_LAUNCH_ARGV=(--harness --fixture-catalog "$FIXTURE_CATALOG")
    if [ -n "${PREVIEW_CACHE:-}" ]; then
        HARNESS_LAUNCH_ARGV+=(--preview-cache "$PREVIEW_CACHE")
    fi
    # --originals-cache defaults to the same scoped dir as DIMROOM_ORIGINALS_DIR
    # so the LRU cache never lands in the user's real Application Support dir.
    # A flow that genuinely wants no --originals-cache sets HARNESS_ORIGINALS_CACHE=none.
    local originals_cache
    originals_cache="${HARNESS_ORIGINALS_CACHE:-$(harness_resolve_originals_dir)}"
    if [ "$originals_cache" != "none" ]; then
        HARNESS_LAUNCH_ARGV+=(--originals-cache "$originals_cache")
    fi
    if [ -n "${SETTINGS_SUITE:-}" ]; then
        HARNESS_LAUNCH_ARGV+=(--settings-suite "$SETTINGS_SUITE")
    fi
    HARNESS_LAUNCH_ARGV+=(${HARNESS_FLAGS[@]+"${HARNESS_FLAGS[@]}"})
}

# Block until the socket appears, the app exits, or the timeout elapses.
# Returns 0 when the socket is ready, non-zero otherwise (so callers can
# compose it — `harness_launch_app` does `|| exit 1`). Never exits the shell
# itself, which keeps it testable.
harness_wait_for_socket() {
    local socket="$1" pid="$2" timeout="${3:-30}" i
    for ((i = 1; i <= timeout; i++)); do
        if [ -e "$socket" ]; then
            echo "Socket ready after ${i}s"
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "ERROR: App exited before socket was ready"
            return 1
        fi
        sleep 1
    done
    echo "ERROR: Socket not ready after ${timeout}s"
    return 1
}

# Launch the app in harness mode and block on its socket. Creates the scoped
# originals dir, assembles env + argv, backgrounds the process into the global
# APP_PID, then waits. Safe to call more than once per flow (relaunch cases).
harness_launch_app() {
    local originals_dir
    originals_dir="$(harness_resolve_originals_dir)"
    mkdir -p "$originals_dir"
    harness_build_env
    harness_build_argv
    env "${HARNESS_LAUNCH_ENV[@]}" "$APP_BIN" "${HARNESS_LAUNCH_ARGV[@]}" &
    APP_PID=$!
    harness_wait_for_socket "$SOCKET" "$APP_PID" "${HARNESS_SOCKET_TIMEOUT:-30}" || exit 1
}
