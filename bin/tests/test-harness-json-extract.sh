#!/usr/bin/env bash
# test-harness-json-extract.sh — Layer A tests for bin/harness-json-extract.
#
# Pipes hand-crafted JSON into the helper and diffs the output against
# expected strings. Covers every DSL feature currently used by the six
# harness flow scripts — a regression in any of these would reintroduce
# the kind of drift issue #115 was filed to prevent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$REPO_ROOT/bin/harness-json-extract"

if [ ! -x "$HELPER" ]; then
    echo "ERROR: helper not executable at $HELPER"
    exit 1
fi

FAILED=0

# assert_eq LABEL EXPECTED ACTUAL
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: $label"
        echo "  expected: $(printf '%q' "$expected")"
        echo "  actual:   $(printf '%q' "$actual")"
        FAILED=1
    else
        echo "  OK: $label"
    fi
}

# assert_fail LABEL JSON ARGS... — runs helper, expects non-zero exit
assert_fail() {
    local label="$1" json="$2"
    shift 2
    if printf '%s' "$json" | "$HELPER" "$@" >/dev/null 2>&1; then
        echo "FAIL: $label — expected non-zero exit"
        FAILED=1
    else
        echo "  OK: $label (exits non-zero as expected)"
    fi
}

echo "=== scalar extraction ==="
OUT=$(printf '{"a": 1}' | "$HELPER" 'a')
assert_eq "top-level scalar" "1" "$OUT"

OUT=$(printf '{"data": {"assetCount": 42}}' | "$HELPER" 'data.assetCount')
assert_eq "nested scalar" "42" "$OUT"

OUT=$(printf '{"data": "hello"}' | "$HELPER" 'data')
assert_eq "string scalar" "hello" "$OUT"

echo "=== index extraction ==="
OUT=$(printf '{"data": [{"id": "X"}, {"id": "Y"}]}' | "$HELPER" 'data[0].id')
assert_eq "index 0" "X" "$OUT"

OUT=$(printf '{"data": [{"id": "X"}, {"id": "Y"}]}' | "$HELPER" 'data[1].id')
assert_eq "index 1" "Y" "$OUT"

OUT=$(printf '{"data": {"assets": [{"id": "Z"}]}}' | "$HELPER" 'data.assets[0].id')
assert_eq "nested list then field" "Z" "$OUT"

echo "=== boolean lowercasing ==="
OUT=$(printf '{"b": true}' | "$HELPER" 'b')
assert_eq "bool true → lowercase" "true" "$OUT"

OUT=$(printf '{"b": false}' | "$HELPER" 'b')
assert_eq "bool false → lowercase" "false" "$OUT"

OUT=$(printf '{"data": {"isZoomed": true}}' | "$HELPER" 'data.isZoomed')
assert_eq "nested bool → lowercase" "true" "$OUT"

echo "=== --default ==="
OUT=$(printf '{"a": 1}' | "$HELPER" 'missing' --default '')
assert_eq "default on missing key" "" "$OUT"

OUT=$(printf '{"a": 1}' | "$HELPER" 'missing' --default 'fallback')
assert_eq "default on missing key (non-empty)" "fallback" "$OUT"

OUT=$(printf '{"a": 1}' | "$HELPER" 'a' --default 'fallback')
assert_eq "default ignored when key present" "1" "$OUT"

OUT=$(printf '{"a": null}' | "$HELPER" 'a' --default '')
assert_eq "default fires on null" "" "$OUT"

OUT=$(printf '{"data": {"selectedAssetId": null}}' | "$HELPER" 'data.selectedAssetId' --default '')
assert_eq "default on nested null (loupe/navigation pattern)" "" "$OUT"

echo "=== --length ==="
OUT=$(printf '{"arr": [1, 2, 3]}' | "$HELPER" 'arr' --length)
assert_eq "array length 3" "3" "$OUT"

OUT=$(printf '{"data": []}' | "$HELPER" 'data' --length)
assert_eq "empty array length" "0" "$OUT"

OUT=$(printf '{"data": {"selectedAssetIds": ["a", "b"]}}' | "$HELPER" 'data.selectedAssetIds' --length)
assert_eq "nested array length" "2" "$OUT"

assert_fail "length on non-array" '{"a": 1}' 'a' --length

echo "=== --iter (path ends in array) ==="
OUT=$(printf '{"ids": ["a", "b", "c"]}' | "$HELPER" 'ids' --iter)
EXPECTED=$'a\nb\nc'
assert_eq "iter scalars" "$EXPECTED" "$OUT"

assert_fail "iter on non-array" '{"a": 1}' 'a' --iter

echo "=== [*] wildcard ==="
OUT=$(printf '{"data": [{"id": "a"}, {"id": "b"}, {"id": "c"}]}' | "$HELPER" 'data[*].id')
EXPECTED=$'a\nb\nc'
assert_eq "wildcard then sub-key (navigation pattern)" "$EXPECTED" "$OUT"

OUT=$(printf '{"data": []}' | "$HELPER" 'data[*].id')
assert_eq "wildcard over empty list" "" "$OUT"

echo "=== --absent ==="
OUT=$(printf '{"a": 1}' | "$HELPER" 'missing' --absent)
assert_eq "absent: missing key" "absent" "$OUT"

OUT=$(printf '{"a": null}' | "$HELPER" 'a' --absent)
assert_eq "absent: null value" "absent" "$OUT"

OUT=$(printf '{"a": 1}' | "$HELPER" 'a' --absent)
assert_eq "absent: present non-null" "present" "$OUT"

OUT=$(printf '{"data": {"cropRect": null}}' | "$HELPER" 'data.cropRect' --absent)
assert_eq "absent: nested null (copypaste pattern)" "absent" "$OUT"

OUT=$(printf '{"data": {"other": 1}}' | "$HELPER" 'data.cropAngle' --absent)
assert_eq "absent: missing nested key (copypaste pattern)" "absent" "$OUT"

OUT=$(printf '{"data": {"cropAngle": 5.0}}' | "$HELPER" 'data.cropAngle' --absent)
assert_eq "absent: present nested key" "present" "$OUT"

echo "=== error paths (missing key without --default) ==="
assert_fail "missing key with no default" '{"a": 1}' 'b'
assert_fail "out-of-range index with no default" '{"a": [1]}' 'a[5]'
assert_fail "invalid JSON" 'not-json' 'a'

echo "=== --float / --equals / --epsilon ==="
OUT=$(printf '{"data": {"exposure": 2}}' | "$HELPER" 'data.exposure' --float)
assert_eq "float round-trip on JSON int" "2.0" "$OUT"

OUT=$(printf '{"a": "3.5"}' | "$HELPER" 'a' --float)
assert_eq "float on string numeric" "3.5" "$OUT"

if printf '{"data": {"exposure": 2.0}}' | "$HELPER" 'data.exposure' --float --equals 2.0 --epsilon 1e-9 >/dev/null; then
    echo "  OK: equals hit (float vs float)"
else
    echo "FAIL: equals hit (float vs float) — expected exit 0"
    FAILED=1
fi

if printf '{"data": {"exposure": 2}}' | "$HELPER" 'data.exposure' --float --equals 2.0 >/dev/null; then
    echo "  OK: equals hit when JSON encodes as int (the bug being fixed)"
else
    echo "FAIL: equals hit when JSON encodes as int — expected exit 0"
    FAILED=1
fi

assert_fail "equals miss" '{"data": {"exposure": 2.0}}' 'data.exposure' --float --equals 2.5

if printf '{"a": 2.0005}' | "$HELPER" 'a' --float --equals 2.0 --epsilon 1e-3 >/dev/null; then
    echo "  OK: epsilon boundary inside window"
else
    echo "FAIL: epsilon boundary inside window — expected exit 0"
    FAILED=1
fi

assert_fail "epsilon boundary outside window" '{"a": 2.002}' 'a' --float --equals 2.0 --epsilon 1e-3

assert_fail "float on non-numeric string" '{"a": "hello"}' 'a' --float
assert_fail "float on boolean" '{"a": true}' 'a' --float
assert_fail "equals without --float" '{"a": 1}' 'a' --equals 1

if printf '{"a": 1}' | "$HELPER" 'missing' --float --default 0 --equals 0 >/dev/null; then
    echo "  OK: --default routes through float compare (hit)"
else
    echo "FAIL: --default routes through float compare (hit) — expected exit 0"
    FAILED=1
fi

assert_fail "--default routes through float compare (miss)" '{"a": 1}' 'missing' --float --default 0 --equals 1

echo "=== zoom flow shape ==="
OUT=$(printf '{"status": "ok", "data": {"isZoomed": false}}' | "$HELPER" 'data.isZoomed')
assert_eq "zoom flow isZoomed false" "false" "$OUT"

OUT=$(printf '{"status": "ok", "data": {"isZoomed": true}}' | "$HELPER" 'data.isZoomed')
assert_eq "zoom flow isZoomed true" "true" "$OUT"

echo "=== library flow shape ==="
OUT=$(printf '{"status": "ok", "data": {"assets": [{"id": "UUID-1"}]}}' | "$HELPER" 'data.assets[0].id')
assert_eq "library flow first asset id" "UUID-1" "$OUT"

OUT=$(printf '{"status": "ok", "data": {"assetCount": 7}}' | "$HELPER" 'data.assetCount')
assert_eq "library flow assetCount" "7" "$OUT"

if [ "$FAILED" -ne 0 ]; then
    echo ""
    echo "=== FAIL: one or more harness-json-extract tests failed ==="
    exit 1
fi

echo ""
echo "=== PASS: all harness-json-extract tests passed ==="
