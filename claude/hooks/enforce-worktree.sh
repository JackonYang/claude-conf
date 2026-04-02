#!/bin/bash
# Claude PreToolUse hook: block branch switching in the main repo.
# Forces worktree usage when switching to a different existing branch.
# Allows: branch creation (-b/-B/-c/-C), file restore (-- path),
#          checkout . (discard), --track, current branch (no-op), worktrees.
#
# Worktree location: ~/.worktrees/<repo>/<slug>/
# Why not ../repo-wt-name (sibling dir): pollutes projects/ with wt debris,
# mixes with real repos, hard to bulk-clean. Centralized dir keeps project
# dirs clean and gives one place to ls/prune all active worktrees.

set -euo pipefail

# jq required for JSON parsing — skip gracefully if missing (e.g., remote servers)
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Skip if not a git checkout/switch command
if ! echo "$COMMAND" | grep -qE 'git\s+(checkout|switch)\s+'; then
    exit 0
fi

# Allow: branch creation (handled by enforce-issue-branch.sh)
if echo "$COMMAND" | grep -qE 'git\s+(checkout\s+-[bB]|switch\s+-[cC])\s+'; then
    exit 0
fi

# Allow: git checkout -- (file restore) or git checkout <ref> -- <path>
if echo "$COMMAND" | grep -qE 'git\s+checkout\s+(.*\s)?--\s+'; then
    exit 0
fi

# Allow: git checkout . (discard all changes)
if echo "$COMMAND" | grep -qE 'git\s+checkout\s+\.\s*$'; then
    exit 0
fi

# Allow: git checkout --track / git switch --track
if echo "$COMMAND" | grep -qE 'git\s+(checkout|switch)\s+--track\s+'; then
    exit 0
fi

# Not inside a git repo — allow (don't crash)
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    exit 0
fi

# Extract target: first non-flag positional argument before --
ARGS_STR=$(echo "$COMMAND" | sed -E 's/.*git[[:space:]]+(checkout|switch)[[:space:]]+//')
TARGET=""
# shellcheck disable=SC2086
set -- $ARGS_STR
while [ "$#" -gt 0 ]; do
    case "$1" in
        --)
            break
            ;;
        -)
            # "git checkout -" means previous branch — treat as positional target
            TARGET="$1"
            break
            ;;
        -*)
            shift
            ;;
        *)
            TARGET="$1"
            break
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    exit 0
fi

# Allow if target is the current branch (no-op)
CURRENT=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD)
if [ "$TARGET" = "$CURRENT" ]; then
    exit 0
fi

# Allow if inside a worktree (not the main repo)
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || true)
GIT_COMMON=$(git rev-parse --git-common-dir 2>/dev/null || true)
if [ -n "$GIT_DIR" ] && [ -n "$GIT_COMMON" ] && [ "$GIT_DIR" != "$GIT_COMMON" ]; then
    exit 0
fi

DENY_REASON="BLOCKED: Direct branch switching is not allowed in the main repo.

  You are on: $CURRENT
  You tried:  git checkout $TARGET

  Use a worktree instead (all worktrees go under ~/.worktrees/<repo>/):
    - Agent tool with isolation: \"worktree\"
    - Agent teams: each team member must use isolation: \"worktree\"
    - Manual: git worktree add ~/.worktrees/$(basename $(git rev-parse --show-toplevel))/<slug> $TARGET

  Why: Switching branches in the main repo disrupts the user's working
  context, invalidates file caches, and causes stale-state errors."

jq -n --arg reason "$DENY_REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
