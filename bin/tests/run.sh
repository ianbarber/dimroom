#!/usr/bin/env bash
# Layer A tests for bin/agent-loop.sh helpers.
# Drives extract_approval_timestamp with fixture JSON payloads — no network.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$REPO_ROOT/bin/tests/fixtures"

# shellcheck source=../agent-loop.sh
. "$REPO_ROOT/bin/agent-loop.sh"

PASS=0
FAIL=0

assert_extract() {
  local name="$1"
  local fixture="$2"
  local want="$3"
  local got
  got=$(extract_approval_timestamp < "$FIXTURES/$fixture")
  if [ "$got" = "$want" ]; then
    printf 'PASS: %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n  want: %q\n  got:  %q\n' "$name" "$want" "$got"
    FAIL=$((FAIL + 1))
  fi
}

assert_extract \
  "approved review picks its submittedAt" \
  "reviews-approved.json" \
  "2026-04-19T02:49:21Z"

assert_extract \
  "LGTM body in a COMMENTED review is treated as approval" \
  "reviews-lgtm-comment.json" \
  "2026-04-19T02:49:21Z"

assert_extract \
  "no approving reviews yields empty string" \
  "reviews-none.json" \
  ""

assert_extract \
  "multiple approvals picks the last submittedAt" \
  "reviews-multiple-approvals.json" \
  "2026-04-19T02:49:21Z"

assert_extract \
  "empty reviews array yields empty string" \
  "reviews-empty.json" \
  ""

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
