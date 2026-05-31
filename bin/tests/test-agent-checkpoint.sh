#!/usr/bin/env bash
# test-agent-checkpoint.sh — Layer A tests for bin/agent-checkpoint.sh, the
# progress-checkpoint helper behind the loop's retry/resume support (#375).
#
# Exercises the write/read/phase round-trip, progress within a session
# (overwrite to a later phase), the fresh-start empty case, atomic-write
# cleanup, and — to satisfy the issue's "demonstrably resumes after a forced
# kill mid-pass" criterion — a SEPARATE PROCESS reading the on-disk checkpoint
# the way a fresh loop pass would after the prior session died. No network.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$REPO_ROOT/bin/agent-checkpoint.sh"

if [ ! -x "$HELPER" ]; then
    echo "ERROR: helper not executable at $HELPER"
    exit 1
fi

# shellcheck source=../agent-checkpoint.sh
. "$HELPER"

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
        bad "$name" "want: $(printf '%q' "$want") / got: $(printf '%q' "$got")"
    fi
}

WORK="$(mktemp -d 2>/dev/null || echo "/tmp/agent-checkpoint-test-$$")"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- fresh start: no checkpoint yet -----------------------------------------

assert_eq "phase on a dir with no checkpoint is empty" \
    "" "$(agent_checkpoint_phase "$WORK")"
assert_eq "read on a dir with no checkpoint is empty" \
    "" "$(agent_checkpoint_read "$WORK")"

# --- write -> read -> phase round-trip --------------------------------------

agent_checkpoint_write "$WORK" "branch-created" "worktree + branch ready"
assert_eq "phase reflects the first write" \
    "branch-created" "$(agent_checkpoint_phase "$WORK")"
assert_eq "notes round-trip through read" \
    "worktree + branch ready" "$(agent_checkpoint_read "$WORK" | jq -r '.notes')"
assert_eq "lastCommit defaults to empty when omitted" \
    "" "$(agent_checkpoint_read "$WORK" | jq -r '.lastCommit')"
if [ -n "$(agent_checkpoint_read "$WORK" | jq -r '.updatedAt // empty')" ]; then
    ok "updatedAt is populated"
else
    bad "updatedAt is populated" "updatedAt was empty"
fi

# --- progress within a session: overwrite to a later phase ------------------

agent_checkpoint_write "$WORK" "code-written" "helper + test done, PR next" "abc1234"
assert_eq "phase advances on overwrite" \
    "code-written" "$(agent_checkpoint_phase "$WORK")"
assert_eq "lastCommit is recorded on overwrite" \
    "abc1234" "$(agent_checkpoint_read "$WORK" | jq -r '.lastCommit')"

# --- notes with shell/JSON metacharacters survive jq escaping ---------------

tricky='quotes " and a slash / and $VAR and a {brace}'
agent_checkpoint_write "$WORK" "tests-passing" "$tricky" "def5678"
assert_eq "metacharacter-laden notes round-trip verbatim" \
    "$tricky" "$(agent_checkpoint_read "$WORK" | jq -r '.notes')"

# --- atomicity: no temp file left behind ------------------------------------

if [ -e "$WORK/.agent-state.json.tmp" ]; then
    bad "no .agent-state.json.tmp left behind" "temp file survived a write"
else
    ok "no .agent-state.json.tmp left behind"
fi

# --- forced-kill resume: a fresh PROCESS recovers the prior phase -----------
# This is the AC #4 demonstration. The functions above ran in-process; here we
# invoke the CLI as a brand-new process — exactly what the next loop pass does
# after the prior `claude` session crashed — and assert it reads the on-disk
# checkpoint rather than seeing a clean slate.

assert_eq "fresh process recovers the last phase via CLI" \
    "tests-passing" "$("$HELPER" phase "$WORK")"
assert_eq "fresh process recovers the last notes via CLI" \
    "$tricky" "$("$HELPER" read "$WORK" | jq -r '.notes')"

# --- CLI dispatch: unknown subcommand fails ---------------------------------

if "$HELPER" bogus "$WORK" >/dev/null 2>&1; then
    bad "unknown subcommand exits non-zero" "bogus subcommand returned 0"
else
    ok "unknown subcommand exits non-zero"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
