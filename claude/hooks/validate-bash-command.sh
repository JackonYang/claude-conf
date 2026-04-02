#!/usr/bin/env bash

set -euo pipefail

# jq required for JSON parsing — skip gracefully if missing
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
command_text=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')

if [[ -z "$command_text" ]]; then
  exit 0
fi

blocked_regex='(^|[[:space:];|&(])((sudo[[:space:]]+)?rm[[:space:]]+-rf[[:space:]]+/($|[[:space:]]))|(mkfs|fdisk|diskutil[[:space:]]+eraseDisk)[[:space:]]|dd[[:space:]]+if='

if printf '%s' "$command_text" | grep -Eiq "$blocked_regex"; then
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
