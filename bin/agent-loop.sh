#!/usr/bin/env bash
# agent-loop.sh — pick the next dimroom issue and run the matching agent prompt.
#
# Usage:
#   bin/agent-loop.sh                 # one pass, exit
#   bin/agent-loop.sh --watch         # loop forever, sleeping between passes
#   bin/agent-loop.sh --issue N       # force a specific issue
#   bin/agent-loop.sh --dry-run       # print what it would do, no execution
#   bin/agent-loop.sh --post-merge N  # run cleanup-artifacts skill for merged PR N
#
# Requirements:
#   - gh authenticated against the dimroom repo
#   - claude CLI on PATH (Claude Code)
#   - run from the repo root

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DRY_RUN=0
WATCH=0
FORCE_ISSUE=""
POST_MERGE_PR=""
SLEEP_SECONDS=300

while [ $# -gt 0 ]; do
  case "$1" in
    --watch) WATCH=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --issue) FORCE_ISSUE="$2"; shift 2 ;;
    --post-merge) POST_MERGE_PR="$2"; shift 2 ;;
    --sleep) SLEEP_SECONDS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { printf '[agent-loop] %s\n' "$*" >&2; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*" >&2
  else
    eval "$@"
  fi
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }
}

require gh
require jq
if [ "$DRY_RUN" -eq 0 ]; then
  require claude
fi

# State precedence: highest priority first.
STATE_PRECEDENCE=(
  "state:changes-requested"
  "state:in-review"
  "state:in-progress"
  "state:planned"
  "state:needs-plan"
)

# Map state label to prompt file.
prompt_for_state() {
  case "$1" in
    state:needs-plan)        echo ".claude/prompts/plan.md" ;;
    state:planned)           echo ".claude/prompts/implement.md" ;;
    state:in-progress)       echo ".claude/prompts/implement.md" ;;
    state:in-review)         echo ".claude/prompts/review.md" ;;
    state:changes-requested) echo ".claude/prompts/respond.md" ;;
    state:ready-to-merge)    echo ".claude/prompts/finalize.md" ;;
    *) echo "" ;;
  esac
}

# Find the next issue to act on.
# Returns "<issue_number> <state_label>" on stdout, or nothing.
next_issue() {
  if [ -n "$FORCE_ISSUE" ]; then
    local labels
    labels=$(gh issue view "$FORCE_ISSUE" --json labels -q '[.labels[].name] | join(",")')
    for s in "${STATE_PRECEDENCE[@]}" "state:ready-to-merge"; do
      if echo ",$labels," | grep -q ",$s,"; then
        echo "$FORCE_ISSUE $s"
        return
      fi
    done
    return
  fi

  for state in "${STATE_PRECEDENCE[@]}" "state:ready-to-merge"; do
    local issue
    issue=$(gh issue list \
              --state open \
              --label "$state" \
              --json number,labels,updatedAt \
              -q 'sort_by(.updatedAt) | .[0].number' 2>/dev/null || true)
    if [ -n "$issue" ] && [ "$issue" != "null" ]; then
      echo "$issue $state"
      return
    fi
  done
}

# Get PR number for an issue, if any.
pr_for_issue() {
  local issue="$1"
  gh pr list --state open --search "linked:issue $issue" \
    --json number,headRefName -q '.[0].number' 2>/dev/null || true
}

# Run a single pass.
do_pass() {
  log "scanning for next issue..."
  local result
  result=$(next_issue || true)
  if [ -z "$result" ]; then
    log "nothing to do"
    return 1
  fi

  local issue state prompt
  issue=$(echo "$result" | awk '{print $1}')
  state=$(echo "$result" | awk '{print $2}')
  prompt=$(prompt_for_state "$state")

  if [ -z "$prompt" ] || [ ! -f "$prompt" ]; then
    log "no prompt for state $state — skipping issue #$issue"
    return 1
  fi

  log "issue #$issue in state $state -> $prompt"

  # Gather issue context for the prompt.
  local title body labels
  title=$(gh issue view "$issue" --json title -q .title)
  body=$(gh issue view "$issue" --json body -q .body)
  labels=$(gh issue view "$issue" --json labels -q '[.labels[].name] | join(",")')

  local pr=""
  if [[ "$state" == state:in-review || "$state" == state:changes-requested || "$state" == state:ready-to-merge ]]; then
    pr=$(pr_for_issue "$issue")
    if [ -z "$pr" ]; then
      log "expected an open PR for issue #$issue in state $state, found none"
      return 1
    fi
  fi

  # Build the env-var preamble appended to the prompt.
  local context
  context=$(cat <<EOF
# Loop context (do not edit)
- ISSUE_NUMBER=$issue
- ISSUE_TITLE=$title
- ISSUE_LABELS=$labels
- PR_NUMBER=${pr:-}

ISSUE_BODY follows below the system marker.
---
$body
EOF
)

  local prompt_file
  prompt_file=$(mktemp -t dimroom-prompt.XXXXXX)
  {
    cat "$prompt"
    echo
    echo "---"
    echo
    echo "$context"
  } > "$prompt_file"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "(dry-run) would invoke claude with prompt at $prompt_file"
    cat "$prompt_file" >&2
    rm -f "$prompt_file"
    return 0
  fi

  log "invoking claude (headless) for issue #$issue stage $state"
  set +e
  ISSUE_NUMBER="$issue" \
  ISSUE_TITLE="$title" \
  ISSUE_LABELS="$labels" \
  PR_NUMBER="$pr" \
  claude \
    --print \
    --permission-mode acceptEdits \
    < "$prompt_file"
  local rc=$?
  set -e

  rm -f "$prompt_file"
  log "claude exited with $rc"
  return 0
}

do_post_merge() {
  local pr="$1"
  log "post-merge cleanup for PR #$pr"
  local prompt_file
  prompt_file=$(mktemp -t dimroom-cleanup.XXXXXX)
  cat > "$prompt_file" <<EOF
Run the cleanup-artifacts skill for merged PR #$pr.

Read .claude/skills/cleanup-artifacts.md and follow it exactly. The PR has just been merged by the human. Resolve ISSUE_NUMBER and BRANCH from \`gh pr view $pr\` before starting.
EOF
  PR_NUMBER="$pr" claude --print --permission-mode acceptEdits < "$prompt_file"
  rm -f "$prompt_file"
}

if [ -n "$POST_MERGE_PR" ]; then
  do_post_merge "$POST_MERGE_PR"
  exit 0
fi

if [ "$WATCH" -eq 1 ]; then
  log "watching every ${SLEEP_SECONDS}s; ctrl-c to stop"
  while true; do
    do_pass || true
    sleep "$SLEEP_SECONDS"
  done
else
  # Keep making passes until there's nothing actionable.
  while do_pass; do
    log "pass complete, checking for next action..."
  done
  log "no more actionable issues — done"
fi
