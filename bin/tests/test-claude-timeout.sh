#!/usr/bin/env bash
# test-claude-timeout.sh — Layer A tests for run_with_timeout() in agent-loop.sh.
#
# Exercises the issue #374 hard-timeout wrapper with sleep-based stubs standing
# in for `claude --print`: exit-code passthrough, stdin+tee plumbing, the
# timeout path (SIGKILL -> 124) and prompt return, and that neither the wedged
# process tree nor the watchdog leaves orphans behind. No network, no real claude.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=../agent-loop.sh
. "$REPO_ROOT/bin/agent-loop.sh"   # defines run_with_timeout; turns on set -euo pipefail

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n  %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
check_eq() { # label want got
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$2 got=$3"; fi
}

# ---------------------------------------------------------------------------
# 1. fast path: a command that exits 0 returns 0.
# ---------------------------------------------------------------------------
rc=0
run_with_timeout 5 /dev/null true || rc=$?
check_eq "exit 0 passes through" 0 "$rc"

# ---------------------------------------------------------------------------
# 2. exit-code passthrough: a command that exits 7 returns 7, not tee's 0.
# ---------------------------------------------------------------------------
rc=0
run_with_timeout 5 /dev/null bash -c 'exit 7' || rc=$?
check_eq "exit 7 passes through" 7 "$rc"

# ---------------------------------------------------------------------------
# 3. stdin + tee: stdin reaches the command and output lands in the logfile.
# ---------------------------------------------------------------------------
log_out="$WORK/tee.log"
rc=0
run_with_timeout 5 "$log_out" cat <<< "DIMROOM_STDIN_TAG_374" || rc=$?
check_eq "stdin command exits 0" 0 "$rc"
if grep -q "DIMROOM_STDIN_TAG_374" "$log_out" 2>/dev/null; then
  pass "stdin is delivered and output tee'd to the logfile"
else
  fail "stdin is delivered and output tee'd to the logfile" "tag missing from $log_out"
fi

# ---------------------------------------------------------------------------
# 4. timeout path: a wedged command is SIGKILLed, returns 124, returns
#    promptly, and leaves no orphaned process tree. The stub records its own
#    pid and a grandchild's pid; both must be dead afterwards (the grandchild
#    proves the whole process group was killed, not just the top process).
# ---------------------------------------------------------------------------
self_pid_file="$WORK/self.pid"
child_pid_file="$WORK/child.pid"
stub="$WORK/wedged-claude"
cat > "$stub" <<EOF
#!/usr/bin/env bash
# Wedged-claude stub: record our pid and a grandchild's pid, then hang. The
# 'sleep 20' is a self-bound so a total failure can't hang CI forever.
echo \$\$ > "$self_pid_file"
sleep 20 &
echo \$! > "$child_pid_file"
wait
EOF
chmod +x "$stub"

SECONDS=0
rc=0
run_with_timeout 1 /dev/null "$stub" || rc=$?
elapsed=$SECONDS

check_eq "wedged command returns the timeout sentinel (124)" 124 "$rc"
if [ "$elapsed" -le 10 ]; then
  pass "timeout fires promptly (${elapsed}s <= 10s)"
else
  fail "timeout fires promptly" "took ${elapsed}s"
fi

self_pid="$(cat "$self_pid_file" 2>/dev/null || true)"
child_pid="$(cat "$child_pid_file" 2>/dev/null || true)"
if [ -n "$self_pid" ] && ! kill -0 "$self_pid" 2>/dev/null; then
  pass "wedged process itself is dead"
else
  fail "wedged process itself is dead" "pid='$self_pid' still alive"
fi
if [ -n "$child_pid" ] && ! kill -0 "$child_pid" 2>/dev/null; then
  pass "grandchild process is reaped (whole group killed)"
else
  fail "grandchild process is reaped (whole group killed)" "pid='$child_pid' still alive"
fi

# ---------------------------------------------------------------------------
# 5. watchdog teardown: after a fast command under a long timeout, the watchdog
#    (and its sleep child) is cleaned up — no stray sleep lingers.
# ---------------------------------------------------------------------------
rc=0
run_with_timeout 41 /dev/null true || rc=$?
check_eq "fast path under a long timeout still returns 0" 0 "$rc"
# Bracket the pattern so pgrep can't match its own argument list.
if pgrep -f 'sleep[ ]41' >/dev/null 2>&1; then
  fail "watchdog sleep is torn down" "a 'sleep 41' is still running"
else
  pass "watchdog sleep is torn down"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
