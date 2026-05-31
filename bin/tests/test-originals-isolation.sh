#!/usr/bin/env bash
# Layer A tests for bin/lib/originals-isolation.sh — the pure path
# classifier behind the harness originals-dir isolation guard (#386,
# Layer C for #367). Sources the lib and drives
# originals_path_is_isolated with crafted paths. No app launch, no
# filesystem, no network — runs in the Ubuntu bash-tests CI job.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=../lib/originals-isolation.sh
. "$REPO_ROOT/bin/lib/originals-isolation.sh"

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

# assert_isolated <name> <resolved> <real_app_support>
assert_isolated() {
    if originals_path_is_isolated "$2" "$3"; then
        ok "$1"
    else
        bad "$1" "expected isolated (0) for resolved='$2'"
    fi
}

# assert_not_isolated <name> <resolved> <real_app_support>
assert_not_isolated() {
    if originals_path_is_isolated "$2" "$3"; then
        bad "$1" "expected NOT isolated (non-zero) for resolved='$2'"
    else
        ok "$1"
    fi
}

REAL="/Users/test/Library/Application Support/Dimroom/originals"

# --- isolated: a per-flow sandbox under the system temp dir -----------------
# Robust to the temp root: /var/folders/…/T (FileManager default), /tmp, and
# the /private/var alias all pass as long as the namespace component is present.
assert_isolated "var-folders temp sandbox is isolated" \
    "/var/folders/qx/abc123/T/dimroom-harness-originals/8ec34f0ca7bec322" "$REAL"
assert_isolated "/tmp sandbox is isolated" \
    "/tmp/dimroom-harness-originals/deadbeef" "$REAL"
assert_isolated "/private/var TMPDIR sandbox is isolated" \
    "/private/var/folders/T/dimroom-harness-originals/cafef00d" "$REAL"

# --- not isolated: the real App Support originals dir (a leak) --------------
assert_not_isolated "real App Support originals dir rejected" \
    "$REAL" "$REAL"
assert_not_isolated "file under App Support originals rejected" \
    "$REAL/index.json" "$REAL"

# --- not isolated: missing the namespace component --------------------------
assert_not_isolated "temp dir without namespace rejected" \
    "/var/folders/qx/abc123/T/some-other-dir/x" "$REAL"

# --- not isolated: empty / garbage input -----------------------------------
assert_not_isolated "empty resolved path rejected" \
    "" "$REAL"
assert_not_isolated "garbage resolved path rejected" \
    "not-a-path" "$REAL"

# --- not isolated: namespace as a filename prefix, not a whole component ----
assert_not_isolated "namespace-prefixed sibling dir rejected" \
    "/tmp/dimroom-harness-originals-leak/x" "$REAL"

# --- classifier holds even without a real-dir argument ---------------------
# The namespace match alone proves isolation; the App-Support exclusion is
# defence in depth and not required when no real path is supplied.
assert_isolated "namespace match with empty real-dir arg is isolated" \
    "/tmp/dimroom-harness-originals/abc" ""

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
