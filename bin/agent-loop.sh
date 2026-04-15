#!/usr/bin/env bash
# agent-loop.sh — pick the next dimroom issue and run the matching agent prompt.
#
# Usage:
#   bin/agent-loop.sh                    # one pass, exit
#   bin/agent-loop.sh --watch            # loop forever, sleeping between passes
#   bin/agent-loop.sh --issue N          # force a specific issue
#   bin/agent-loop.sh --dry-run          # print what it would do, no execution
#   bin/agent-loop.sh --post-merge N     # run cleanup-artifacts skill for merged PR N
#   bin/agent-loop.sh --planner-only     # only plan needs-plan issues
#   bin/agent-loop.sh --reviewer-only    # only review in-review PRs
#   bin/agent-loop.sh --implementer-only # only implement planned / in-progress / changes-requested
#
# Parallel setup — run each in a separate terminal:
#   Terminal 1: bin/agent-loop.sh --watch --planner-only
#   Terminal 2: bin/agent-loop.sh --watch --implementer-only
#   Terminal 3: bin/agent-loop.sh --watch --reviewer-only
# Each owns different state labels so they don't race on the same issue.
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
PLANNER_ONLY=0
REVIEWER_ONLY=0
IMPLEMENTER_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --watch) WATCH=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --issue) FORCE_ISSUE="$2"; shift 2 ;;
    --post-merge) POST_MERGE_PR="$2"; shift 2 ;;
    --sleep) SLEEP_SECONDS="$2"; shift 2 ;;
    --planner-only) PLANNER_ONLY=1; shift ;;
    --reviewer-only) REVIEWER_ONLY=1; shift ;;
    --implementer-only) IMPLEMENTER_ONLY=1; shift ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Enforce mutual exclusivity of the role-specific modes.
MODE_COUNT=$((PLANNER_ONLY + REVIEWER_ONLY + IMPLEMENTER_ONLY))
if [ "$MODE_COUNT" -gt 1 ]; then
  echo "--planner-only, --reviewer-only, and --implementer-only are mutually exclusive" >&2
  exit 2
fi

LOG_DIR="$REPO_ROOT/.artifacts/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/agent-loop-$(date +%Y%m%d-%H%M%S).log"

log() {
  local msg
  msg="[agent-loop $(date +%H:%M:%S)] $*"
  printf '%s\n' "$msg" >&2
  printf '%s\n' "$msg" >> "$LOG_FILE"
}
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*" >&2
  else
    eval "$@"
  fi
}

log "log file: $LOG_FILE"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }
}

require gh
require jq
if [ "$DRY_RUN" -eq 0 ]; then
  require claude
fi

# State precedence: highest priority first.
#
# Role-specific modes restrict the precedence list so multiple loops
# can run in parallel without racing on the same issue. Each mode owns
# a disjoint set of state labels.
if [ "$PLANNER_ONLY" -eq 1 ]; then
  STATE_PRECEDENCE=(
    "state:needs-plan"
  )
  log "planner-only mode: only processing state:needs-plan"
elif [ "$REVIEWER_ONLY" -eq 1 ]; then
  STATE_PRECEDENCE=(
    "state:in-review"
  )
  log "reviewer-only mode: only processing state:in-review"
elif [ "$IMPLEMENTER_ONLY" -eq 1 ]; then
  STATE_PRECEDENCE=(
    "state:changes-requested"
    "state:in-progress"
    "state:planned"
  )
  log "implementer-only mode: processing changes-requested / in-progress / planned"
else
  STATE_PRECEDENCE=(
    "state:changes-requested"
    "state:in-review"
    "state:in-progress"
    "state:planned"
    "state:needs-plan"
  )
fi

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
#
# GitHub's PR search has a `linked:issue` qualifier but it is a boolean —
# it filters PRs that have *any* linked issue, ignoring the argument. We
# instead match the branch naming convention `issue-{number}-*`, which is
# enforced by CLAUDE.md and so is a reliable key. See issue #19.
pr_for_issue() {
  local issue="$1"
  gh pr list --state open \
    --json number,headRefName \
    -q ".[] | select(.headRefName | startswith(\"issue-${issue}-\")) | .number" \
    2>/dev/null | head -n1
}

# Check ready-to-merge PRs for merge conflicts or new human comments.
# If found, flip the issue back to state:changes-requested so the
# responder picks it up and fixes the problem.
check_ready_to_merge() {
  local issues
  issues=$(gh issue list --state open --label "state:ready-to-merge" \
    --json number -q '.[].number' 2>/dev/null || true)
  [ -z "$issues" ] && return

  for issue in $issues; do
    local pr
    pr=$(pr_for_issue "$issue")
    [ -z "$pr" ] && continue

    # Check for merge conflicts.
    local mergeable
    mergeable=$(gh pr view "$pr" --json mergeable -q .mergeable 2>/dev/null || true)
    if [ "$mergeable" = "CONFLICTING" ]; then
      log "PR #$pr (issue #$issue) has merge conflicts — moving to changes-requested"
      gh issue edit "$issue" --remove-label "state:ready-to-merge" --add-label "state:changes-requested" 2>/dev/null
      gh pr comment "$pr" --body "Merge conflicts detected. Moving to \`state:changes-requested\` for the responder to rebase." 2>/dev/null || true
      continue
    fi

    # Check for new human comments after the last bot comment.
    # If the human left feedback, the responder should address it.
    local human_comment
    human_comment=$(gh pr view "$pr" --json comments \
      -q '[.comments[] | select(.author.login != "github-actions" and .author.login != "claude")] | last | .createdAt' 2>/dev/null || true)
    local bot_comment
    bot_comment=$(gh pr view "$pr" --json comments \
      -q '[.comments[] | select(.body | test("ready.to.merge|ready for human merge|LGTM|approved"; "i"))] | last | .createdAt' 2>/dev/null || true)

    if [ -n "$human_comment" ] && [ -n "$bot_comment" ] && [[ "$human_comment" > "$bot_comment" ]]; then
      log "PR #$pr (issue #$issue) has new human comment after approval — moving to changes-requested"
      gh issue edit "$issue" --remove-label "state:ready-to-merge" --add-label "state:changes-requested" 2>/dev/null
      continue
    fi
  done
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
    --dangerously-skip-permissions \
    < "$prompt_file" 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
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

sync_main() {
  log "pulling latest main..."
  # Serialize pulls across parallel loops with a mkdir-based lock
  # (atomic on POSIX, works on macOS where flock isn't available).
  # Without this, concurrent `git pull` calls produce
  # "Cannot fast-forward to multiple branches" errors.
  local lockdir="$REPO_ROOT/.artifacts/sync-main.lock.d"
  mkdir -p "$(dirname "$lockdir")"
  local waited=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    if [ "$waited" -ge 60 ]; then
      log "  sync_main: lock timeout after 60s; skipping pull this pass"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT RETURN
  git pull --ff-only origin main 2>&1 | while read -r line; do log "  $line"; done || \
    log "  sync_main: non-fatal pull issue, continuing"
  rmdir "$lockdir" 2>/dev/null || true
  trap - EXIT RETURN
}

if [ "$WATCH" -eq 1 ]; then
  log "watching every ${SLEEP_SECONDS}s; ctrl-c to stop"
  while true; do
    # Wrap each pass's prelude in || true so a network blip (overnight
    # sleep, flaky connection, github SSH hiccup) doesn't kill the loop.
    # The loop stays alive and tries again next pass.
    sync_main || log "sync_main failed, continuing"
    check_ready_to_merge || log "check_ready_to_merge failed, continuing"
    do_pass || true
    sleep "$SLEEP_SECONDS"
  done
else
  sync_main || log "sync_main failed, continuing"
  check_ready_to_merge || log "check_ready_to_merge failed, continuing"
  # Keep making passes until there's nothing actionable.
  while do_pass; do
    log "pass complete, checking for next action..."
    sync_main || log "sync_main failed, continuing"
    check_ready_to_merge || log "check_ready_to_merge failed, continuing"
  done
  log "no more actionable issues — done"
fi
