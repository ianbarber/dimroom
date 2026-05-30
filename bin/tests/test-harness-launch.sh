#!/usr/bin/env bash
# Layer A tests for bin/lib/harness-launch.sh — the shared harness app-launch
# helper (#366). Sources the helper and drives its pure, array-populating
# functions plus the wait-for-socket loop. No app launch, no network — runs in
# the Ubuntu bash-tests CI job.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=../lib/harness-launch.sh
. "$REPO_ROOT/bin/lib/harness-launch.sh"

PASS=0
FAIL=0

ok() {
    printf 'PASS: %s\n' "$1"
    PASS=$((PASS + 1))
}

bad() {
    printf 'FAIL: %s\n  %s\n' "$1" "$2"
    FAIL=$((FAIL + 1))
}

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then
        ok "$name"
    else
        bad "$name" "want: $want / got: $got"
    fi
}

# True if HARNESS_LAUNCH_ARGV contains $1 as a standalone element.
argv_has() {
    local needle="$1" e
    for e in "${HARNESS_LAUNCH_ARGV[@]}"; do
        [ "$e" = "$needle" ] && return 0
    done
    return 1
}

# True if HARNESS_LAUNCH_ARGV contains flag $1 immediately followed by value $2.
argv_pair() {
    local flag="$1" val="$2" i
    for ((i = 0; i < ${#HARNESS_LAUNCH_ARGV[@]}; i++)); do
        if [ "${HARNESS_LAUNCH_ARGV[$i]}" = "$flag" ]; then
            [ "${HARNESS_LAUNCH_ARGV[$((i + 1))]:-}" = "$val" ] && return 0
        fi
    done
    return 1
}

# True if HARNESS_LAUNCH_ENV contains $1 as a standalone element.
env_has() {
    local needle="$1" e
    for e in "${HARNESS_LAUNCH_ENV[@]}"; do
        [ "$e" = "$needle" ] && return 0
    done
    return 1
}

# Reset the caller-convention globals between cases so each test is isolated.
reset_globals() {
    unset DIMROOM_ORIGINALS_DIR HARNESS_ORIGINALS_DIR HARNESS_WORK_DIR \
        PREVIEW_CACHE SETTINGS_SUITE HARNESS_ORIGINALS_CACHE \
        FIXTURE_CATALOG SOCKET 2>/dev/null || true
    HARNESS_ENV=()
    HARNESS_FLAGS=()
}

# --- harness_resolve_originals_dir -----------------------------------------

reset_globals
HARNESS_WORK_DIR="/tmp/wd"
assert_eq "resolve defaults to \$HARNESS_WORK_DIR/originals" \
    "/tmp/wd/originals" "$(harness_resolve_originals_dir)"

reset_globals
HARNESS_WORK_DIR="/tmp/wd"
HARNESS_ORIGINALS_DIR="/tmp/explicit-orig"
assert_eq "resolve honours HARNESS_ORIGINALS_DIR over the default" \
    "/tmp/explicit-orig" "$(harness_resolve_originals_dir)"

reset_globals
HARNESS_WORK_DIR="/tmp/wd"
DIMROOM_ORIGINALS_DIR="/tmp/env-orig"
assert_eq "resolve honours a pre-set DIMROOM_ORIGINALS_DIR" \
    "/tmp/env-orig" "$(harness_resolve_originals_dir)"

# --- harness_build_argv -----------------------------------------------------

reset_globals
HARNESS_WORK_DIR="/tmp/wd"
FIXTURE_CATALOG="/tmp/cat.sqlite"
harness_build_argv
if argv_has "--harness"; then ok "argv includes --harness"; else bad "argv includes --harness" "argv: ${HARNESS_LAUNCH_ARGV[*]}"; fi
if argv_pair "--fixture-catalog" "/tmp/cat.sqlite"; then ok "argv carries --fixture-catalog value"; else bad "argv carries --fixture-catalog value" "argv: ${HARNESS_LAUNCH_ARGV[*]}"; fi
if argv_pair "--originals-cache" "/tmp/wd/originals"; then ok "argv scopes --originals-cache by default"; else bad "argv scopes --originals-cache by default" "argv: ${HARNESS_LAUNCH_ARGV[*]}"; fi
if argv_has "--preview-cache"; then bad "argv omits --preview-cache when unset" "argv: ${HARNESS_LAUNCH_ARGV[*]}"; else ok "argv omits --preview-cache when unset"; fi
if argv_has "--settings-suite"; then bad "argv omits --settings-suite when unset" "argv: ${HARNESS_LAUNCH_ARGV[*]}"; else ok "argv omits --settings-suite when unset"; fi

reset_globals
HARNESS_WORK_DIR="/tmp/wd"
FIXTURE_CATALOG="/tmp/cat.sqlite"
PREVIEW_CACHE="/tmp/prev"
SETTINGS_SUITE="com.test.suite"
HARNESS_FLAGS=(--drive-backed)
harness_build_argv
if argv_pair "--preview-cache" "/tmp/prev"; then ok "argv passes --preview-cache when set"; else bad "argv passes --preview-cache when set" "argv: ${HARNESS_LAUNCH_ARGV[*]}"; fi
if argv_pair "--settings-suite" "com.test.suite"; then ok "argv passes --settings-suite when set"; else bad "argv passes --settings-suite when set" "argv: ${HARNESS_LAUNCH_ARGV[*]}"; fi
if argv_has "--drive-backed"; then ok "argv appends HARNESS_FLAGS[@]"; else bad "argv appends HARNESS_FLAGS[@]" "argv: ${HARNESS_LAUNCH_ARGV[*]}"; fi

reset_globals
HARNESS_WORK_DIR="/tmp/wd"
FIXTURE_CATALOG="/tmp/cat.sqlite"
HARNESS_ORIGINALS_CACHE="none"
harness_build_argv
if argv_has "--originals-cache"; then bad "argv omits --originals-cache when opted out" "argv: ${HARNESS_LAUNCH_ARGV[*]}"; else ok "argv omits --originals-cache when opted out (none)"; fi

# --- harness_build_env ------------------------------------------------------

reset_globals
HARNESS_WORK_DIR="/tmp/wd"
SOCKET="/tmp/x.sock"
HARNESS_ENV=(FOO=bar BAZ=qux)
harness_build_env
if env_has "DIMROOM_HARNESS_SOCKET=/tmp/x.sock"; then ok "env carries DIMROOM_HARNESS_SOCKET"; else bad "env carries DIMROOM_HARNESS_SOCKET" "env: ${HARNESS_LAUNCH_ENV[*]}"; fi
if env_has "DIMROOM_ORIGINALS_DIR=/tmp/wd/originals"; then ok "env carries scoped DIMROOM_ORIGINALS_DIR"; else bad "env carries scoped DIMROOM_ORIGINALS_DIR" "env: ${HARNESS_LAUNCH_ENV[*]}"; fi
if env_has "FOO=bar" && env_has "BAZ=qux"; then ok "env appends HARNESS_ENV[@]"; else bad "env appends HARNESS_ENV[@]" "env: ${HARNESS_LAUNCH_ENV[*]}"; fi

reset_globals
HARNESS_WORK_DIR="/tmp/wd"
SOCKET="/tmp/x.sock"
harness_build_env
assert_eq "env has exactly socket + originals when HARNESS_ENV empty" \
    "2" "${#HARNESS_LAUNCH_ENV[@]}"

# --- harness_wait_for_socket ------------------------------------------------

ready_sock="$(mktemp -u 2>/dev/null || echo "/tmp/dimroom-wait-ready-$$")"
: > "$ready_sock"
if harness_wait_for_socket "$ready_sock" "$$" 2 >/dev/null; then
    ok "wait_for_socket returns 0 on an existing socket"
else
    bad "wait_for_socket returns 0 on an existing socket" "returned non-zero for present path"
fi
rm -f "$ready_sock"

absent_sock="$(mktemp -u 2>/dev/null || echo "/tmp/dimroom-wait-absent-$$")"
rm -f "$absent_sock"
# Live pid ($$), absent socket, 1s timeout -> must return non-zero (timeout).
if harness_wait_for_socket "$absent_sock" "$$" 1 >/dev/null; then
    bad "wait_for_socket times out against a live pid" "returned 0 despite missing socket"
else
    ok "wait_for_socket times out (non-zero) against a live pid"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
