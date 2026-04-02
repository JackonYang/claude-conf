#!/usr/bin/env bash

set -euo pipefail

# jq required for JSON parsing — skip gracefully if missing
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
command_text=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')

if [[ -z "$command_text" ]]; then
  exit 0
fi

# Strip quoted strings before matching to avoid false positives
# e.g. gh issue create --body "rm -rf /" should NOT be blocked
stripped_command=$(printf '%s' "$command_text" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")

blocked_regex='(^|[[:space:];|&(])((sudo[[:space:]]+)?rm[[:space:]]+-rf[[:space:]]+/($|[[:space:]);|&]))|(mkfs|fdisk|diskutil[[:space:]]+eraseDisk)[[:space:]]|dd[[:space:]]+if='

if printf '%s' "$stripped_command" | grep -Eiq "$blocked_regex"; then
  jq -n --arg reason "Blocked risky bash command in bypass mode: $command_text" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

exit 0
