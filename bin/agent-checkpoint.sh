#!/usr/bin/env bash
# agent-checkpoint.sh — read/write a lightweight progress checkpoint for the
# agent loop (issue #375).
#
# A stage session (implement / respond) writes a checkpoint as it reaches each
# milestone. If the session crashes (socket error, API outage, timeout) or hands
# off because it is running low on context, the next loop pass reads the
# checkpoint and resumes from the recorded phase instead of starting over.
#
# The checkpoint lives at <dir>/.agent-state.json where <dir> is the issue
# worktree (e.g. .worktrees/issue-352). It is gitignored, so a WIP handoff
# commit never drags it into the PR diff.
#
# Schema (.agent-state.json):
#   {
#     "phase":      "<milestone>",   # e.g. branch-created | code-written |
#                                    #      tests-passing | pr-opened
#     "lastCommit": "<sha>",         # last commit on the branch ("" if none yet)
#     "notes":      "<free text>",   # what's done / what's left
#     "updatedAt":  "<iso-8601 utc>" # date -u +%Y-%m-%dT%H:%M:%SZ
#   }
#
# Usage (CLI):
#   bin/agent-checkpoint.sh write <dir> <phase> <notes> [commit_sha]
#   bin/agent-checkpoint.sh read  <dir>     # prints the JSON ("" if absent)
#   bin/agent-checkpoint.sh phase <dir>     # prints just .phase ("" if absent)
#
# Usage (sourced): the same three operations are exposed as functions
#   agent_checkpoint_write / agent_checkpoint_read / agent_checkpoint_phase.
#
# Only dependency is jq (already required by the loop).

# Path to the checkpoint file inside an issue worktree dir.
_agent_checkpoint_file() {
    printf '%s/.agent-state.json' "$1"
}

# write <dir> <phase> <notes> [commit_sha] — atomically replace the checkpoint.
agent_checkpoint_write() {
    local dir="$1" phase="$2" notes="$3" commit="${4:-}"
    local file tmp updated
    file="$(_agent_checkpoint_file "$dir")"
    tmp="${file}.tmp"
    updated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    jq -n \
        --arg phase "$phase" \
        --arg lastCommit "$commit" \
        --arg notes "$notes" \
        --arg updatedAt "$updated" \
        '{phase: $phase, lastCommit: $lastCommit, notes: $notes, updatedAt: $updatedAt}' \
        > "$tmp"
    mv -f "$tmp" "$file"
}

# read <dir> — print the checkpoint JSON, or nothing if there is no checkpoint.
agent_checkpoint_read() {
    local file
    file="$(_agent_checkpoint_file "$1")"
    [ -f "$file" ] && cat "$file"
}

# phase <dir> — print just the recorded phase, or nothing if there is no
# checkpoint. This is the first call a resuming session makes to decide where
# to pick up.
agent_checkpoint_phase() {
    local file
    file="$(_agent_checkpoint_file "$1")"
    [ -f "$file" ] && jq -r '.phase // empty' "$file"
}

_agent_checkpoint_usage() {
    cat >&2 <<'EOF'
usage:
  agent-checkpoint.sh write <dir> <phase> <notes> [commit_sha]
  agent-checkpoint.sh read  <dir>
  agent-checkpoint.sh phase <dir>
EOF
}

# Subcommand dispatcher, shared by the CLI entrypoint.
agent_checkpoint() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        write) agent_checkpoint_write "$@" ;;
        read)  agent_checkpoint_read "$@" ;;
        phase) agent_checkpoint_phase "$@" ;;
        *) _agent_checkpoint_usage; return 2 ;;
    esac
}

# Run as a CLI when executed directly; expose functions when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    agent_checkpoint "$@"
fi
