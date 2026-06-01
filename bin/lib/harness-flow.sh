#!/usr/bin/env bash
# bin/lib/harness-flow.sh — shared boilerplate for Layer C harness flows
# (#402, follow-up to #383's launch-block extraction in harness-launch.sh).
#
# SOURCE this file (do not execute it). Once #383 folded the launch+wait
# block into harness-launch.sh, three other blocks were still copy-pasted by
# nearly every `bin/harness-*-flow.sh`; this helper owns them so a flow keeps
# only its flow-specific logic:
#
#   harness_cleanup            the kill-app + rm-socket EXIT-trap body
#   harness_locate_binaries    the APP_BIN/CLI_BIN/FIXTURE_BIN path resolution
#   harness_require_binaries   the "missing binary …" executable guard
#   assert_json_field*         the JSON-field assertion helpers
#
# Usage from a flow (alongside the harness-launch.sh source line):
#
#     . "$REPO_ROOT/bin/lib/harness-flow.sh"
#
#     SOCKET="/tmp/dimroom-harness-myflow-$$.sock"
#     APP_PID=""
#     trap harness_cleanup EXIT
#
#     harness_locate_binaries                                  # sets the *_BIN globals
#     harness_require_binaries "$APP_BIN" "$CLI_BIN" || exit 1 # guard the ones used
#
# Conventions read from the caller's globals:
#   APP_PID    pid of the launched app (may be empty or already dead)
#   SOCKET     control-socket path to remove on exit
#   REPO_ROOT  repo root; resolves the *_BIN paths and bin/harness-json-extract
#
# The locate/require split mirrors harness-launch.sh's pure functions so it
# stays unit-testable (bin/tests/test-harness-flow.sh) without launching the
# GUI app: locate only assigns globals, require *returns* non-zero (it never
# `exit`s) so a test can probe both outcomes.

# Kill the app (if still running) and remove the control socket. Flows install
# it with `trap harness_cleanup EXIT`. Reads $APP_PID and $SOCKET; a no-op when
# APP_PID is empty/unset or its process is already gone.
harness_cleanup() {
    if [ -n "${APP_PID:-}" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -f "${SOCKET:-}"
}

# Resolve the standard harness binary paths from $REPO_ROOT into the globals
# APP_BIN, CLI_BIN, FIXTURE_BIN. Pure: only assigns globals. A flow that uses
# just two of them still gets the third set harmlessly.
harness_locate_binaries() {
    APP_BIN="$REPO_ROOT/App/.build/debug/Dimroom"
    CLI_BIN="$REPO_ROOT/Packages/Harness/.build/debug/dimroom-cli"
    FIXTURE_BIN="$REPO_ROOT/Packages/Harness/.build/debug/dimroom-fixture"
}

# Verify each passed path is an executable file. Prints the unified error and
# RETURNS non-zero on the first missing binary (does not `exit`), so it stays
# unit-testable; flows compose it as
# `harness_require_binaries "$APP_BIN" "$CLI_BIN" || exit 1`.
harness_require_binaries() {
    local bin
    for bin in "$@"; do
        if [ ! -x "$bin" ]; then
            echo "ERROR: missing binary $bin — capture-screenshots skill should have built it"
            return 1
        fi
    done
    return 0
}

# JSON-field assertion helpers. Each shells out to bin/harness-json-extract and
# `exit 1`s on a mismatch (aborting the flow), so flows that source this helper
# must call them at top level — not in a subshell whose exit they'd swallow.

# Assert a field equals an exact string. Usage:
#   assert_json_field <label> <json> <field> <expected>
assert_json_field() {
    local label="$1" json="$2" field="$3" expected="$4"
    local actual
    actual=$(printf '%s' "$json" | "$REPO_ROOT/bin/harness-json-extract" "$field")
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: $label — expected $field == $expected, got $actual"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — $field == $expected"
}

# Assert a field is present (non-null). Usage:
#   assert_json_field_present <label> <json> <field>
assert_json_field_present() {
    local label="$1" json="$2" field="$3"
    local present
    present=$(printf '%s' "$json" | "$REPO_ROOT/bin/harness-json-extract" "$field" --absent)
    if [ "$present" != "present" ]; then
        echo "ERROR: $label — expected $field to be present"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — $field present"
}

# Assert a field is absent or null. Usage:
#   assert_json_field_absent <label> <json> <field>
assert_json_field_absent() {
    local label="$1" json="$2" field="$3"
    local present
    present=$(printf '%s' "$json" | "$REPO_ROOT/bin/harness-json-extract" "$field" --absent)
    if [ "$present" != "absent" ]; then
        echo "ERROR: $label — expected $field to be absent or null"
        echo "Response: $json"
        exit 1
    fi
    echo "  OK: $label — $field absent/null"
}

# Assert a numeric field equals expected within a tight epsilon. Usage:
#   assert_json_number <label> <json> <field> <expected>
assert_json_number() {
    local label="$1" json="$2" field="$3" expected="$4"
    if printf '%s' "$json" | "$REPO_ROOT/bin/harness-json-extract" "$field" --float --equals "$expected" --epsilon 1e-9; then
        echo "  OK: $label — $field ≈ $expected"
        return
    fi
    local actual
    actual=$(printf '%s' "$json" | "$REPO_ROOT/bin/harness-json-extract" "$field" --float 2>/dev/null || echo '?')
    echo "ERROR: $label — expected $field == $expected, got $actual"
    echo "Response: $json"
    exit 1
}
