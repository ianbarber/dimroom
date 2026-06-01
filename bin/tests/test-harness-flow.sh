#!/usr/bin/env bash
# Layer A tests for bin/lib/harness-flow.sh — the shared harness-flow helper
# (#402). Sources the helper and drives its pure functions (binary locate +
# require, cleanup) plus the JSON-field assertion helpers. No app launch, no
# network — runs in the Ubuntu bash-tests CI job (harness-json-extract is a
# Python script, so the assert helpers are exercisable there).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=../lib/harness-flow.sh
. "$REPO_ROOT/bin/lib/harness-flow.sh"

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

# --- harness_locate_binaries ------------------------------------------------
# Pure: reads $REPO_ROOT, assigns the three *_BIN globals. Drive it under a
# stub REPO_ROOT in a subshell so the real one (needed by the assert helpers
# below) is left intact.

read -r LOC_APP LOC_CLI LOC_FIXTURE < <(
    REPO_ROOT="/stub/root"
    harness_locate_binaries
    printf '%s %s %s\n' "$APP_BIN" "$CLI_BIN" "$FIXTURE_BIN"
)
assert_eq "locate sets APP_BIN" "/stub/root/App/.build/debug/Dimroom" "$LOC_APP"
assert_eq "locate sets CLI_BIN" "/stub/root/Packages/Harness/.build/debug/dimroom-cli" "$LOC_CLI"
assert_eq "locate sets FIXTURE_BIN" "/stub/root/Packages/Harness/.build/debug/dimroom-fixture" "$LOC_FIXTURE"

# --- harness_require_binaries -----------------------------------------------

req_tmp="$(mktemp -d 2>/dev/null || echo "/tmp/dimroom-require-$$")"
mkdir -p "$req_tmp"
: > "$req_tmp/a"
: > "$req_tmp/b"
chmod +x "$req_tmp/a" "$req_tmp/b"

if harness_require_binaries "$req_tmp/a" "$req_tmp/b" >/dev/null 2>&1; then
    ok "require returns 0 when all paths are executable"
else
    bad "require returns 0 when all paths are executable" "returned non-zero for executable files"
fi

req_out="$(harness_require_binaries "$req_tmp/a" "$req_tmp/missing" 2>&1)"
req_rc=$?
if [ "$req_rc" -ne 0 ]; then
    ok "require returns non-zero when a path is missing"
else
    bad "require returns non-zero when a path is missing" "returned 0 despite a missing binary"
fi
if printf '%s' "$req_out" | grep -q "$req_tmp/missing"; then
    ok "require names the missing binary"
else
    bad "require names the missing binary" "message did not mention the offender: $req_out"
fi

# A present-but-not-executable file is also rejected.
: > "$req_tmp/c"
chmod -x "$req_tmp/c"
if harness_require_binaries "$req_tmp/a" "$req_tmp/c" >/dev/null 2>&1; then
    bad "require rejects a non-executable file" "returned 0 for a chmod -x file"
else
    ok "require rejects a non-executable file"
fi
rm -rf "$req_tmp"

# --- harness_cleanup --------------------------------------------------------
# rm -f's $SOCKET and is a no-op for the app process when APP_PID is empty or
# names a dead/absent process. No real app is launched.

clean_sock="$(mktemp -u 2>/dev/null || echo "/tmp/dimroom-cleanup-$$.sock")"
: > "$clean_sock"
(
    APP_PID=""
    SOCKET="$clean_sock"
    harness_cleanup
)
clean_rc=$?
if [ "$clean_rc" -eq 0 ]; then
    ok "cleanup returns 0 with an empty APP_PID"
else
    bad "cleanup returns 0 with an empty APP_PID" "returned $clean_rc"
fi
if [ ! -e "$clean_sock" ]; then
    ok "cleanup removes the socket"
else
    bad "cleanup removes the socket" "socket still present at $clean_sock"
    rm -f "$clean_sock"
fi

# Dead/absent pid: kill -0 fails, so no kill/wait — still removes the socket.
clean_sock2="$(mktemp -u 2>/dev/null || echo "/tmp/dimroom-cleanup2-$$.sock")"
: > "$clean_sock2"
(
    APP_PID="999999"   # a pid extremely unlikely to be live
    SOCKET="$clean_sock2"
    harness_cleanup
)
if [ ! -e "$clean_sock2" ]; then
    ok "cleanup is a no-op kill but still removes the socket for a dead pid"
else
    bad "cleanup handles a dead pid" "socket still present at $clean_sock2"
    rm -f "$clean_sock2"
fi

# --- assert_json_field* -----------------------------------------------------
# These `exit 1` on a failed assertion, so run each in a subshell and probe its
# exit code: 0 on a passing assertion, non-zero on a failing one. They shell
# out to $REPO_ROOT/bin/harness-json-extract, hence the real REPO_ROOT above.

J='{"status":"ok","data":{"exposure":2.0,"present":5,"missing":null}}'

probe() {  # probe <expect-rc> <name> -- <assert call...>
    local want_rc="$1" name="$2"
    shift 3   # drop want_rc, name, and the literal '--'
    ( "$@" ) >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ] && [ "$want_rc" -eq 0 ]; then
        ok "$name"
    elif [ "$rc" -ne 0 ] && [ "$want_rc" -ne 0 ]; then
        ok "$name"
    else
        bad "$name" "want rc $want_rc, got $rc"
    fi
}

probe 0 "assert_json_field matches" -- assert_json_field "status" "$J" "status" "ok"
probe 1 "assert_json_field detects a mismatch" -- assert_json_field "status" "$J" "status" "nope"
probe 0 "assert_json_field_present sees a present field" -- assert_json_field_present "present" "$J" "data.present"
probe 1 "assert_json_field_present fails on a null field" -- assert_json_field_present "missing" "$J" "data.missing"
probe 0 "assert_json_field_absent sees a null field as absent" -- assert_json_field_absent "missing" "$J" "data.missing"
probe 1 "assert_json_field_absent fails on a present field" -- assert_json_field_absent "present" "$J" "data.present"
probe 0 "assert_json_number matches within epsilon" -- assert_json_number "exposure" "$J" "data.exposure" "2.0"
probe 1 "assert_json_number detects an out-of-epsilon value" -- assert_json_number "exposure" "$J" "data.exposure" "9.0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
