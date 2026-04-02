#!/bin/bash
# Claude PreToolUse hook: enforce branch naming convention with issue number.
# Blocks branch creation unless name matches <type>/<issue#>-<desc>.
# Covers: git checkout -b/-B, git switch -c/-C, git worktree add ... -b/-B
# Valid types: feat, fix, tune, ops, chore, experiment

set -euo pipefail

# jq required for JSON parsing — skip gracefully if missing (e.g., remote servers)
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Detect branch creation: checkout -b/-B, switch -c/-C, worktree add ... -b/-B
if ! echo "$COMMAND" | grep -qE 'git\s+(checkout\s+-[bB]|switch\s+-[cC]|worktree\s+add\s+.*\s+-[bB])\s+'; then
    exit 0
fi

# Extract the branch name
# For checkout -b/-B or switch -c/-C: next arg after the flag
# For worktree add <path> -b/-B <branch>: next arg after -b/-B
BRANCH=$(echo "$COMMAND" | grep -oE '(checkout\s+-[bB]|switch\s+-[cC])\s+(\S+)' | awk '{print $NF}' || true)
if [ -z "$BRANCH" ]; then
    BRANCH=$(echo "$COMMAND" | grep -oE '\s-[bB]\s+(\S+)' | awk '{print $NF}' || true)
fi

if [ -z "$BRANCH" ]; then
    exit 0
fi

# Validate: <type>/<issue-number>-<description>
if echo "$BRANCH" | grep -qE '^(feat|fix|tune|ops|chore|experiment)/[0-9]+-[a-z0-9][a-z0-9-]*$'; then
    exit 0
fi

DENY_REASON="BLOCKED: Branch name '$BRANCH' does not follow the required convention.

  Required format: <type>/<issue-number>-<description>
  Example: feat/42-add-issue-first-workflow

  Valid types: feat, fix, tune, ops, chore, experiment

  Steps:
    1. Create a GitHub issue first: gh issue create --title '...'
    2. Use the issue number in the branch name
    3. git checkout -b feat/<issue#>-<short-description>"

jq -n --arg reason "$DENY_REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
