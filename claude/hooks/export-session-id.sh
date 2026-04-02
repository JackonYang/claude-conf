#!/bin/sh
# Export session_id so Bash tool calls can write per-session .goal files
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // empty')
if [ -n "$session_id" ] && [ -n "$CLAUDE_ENV_FILE" ]; then
  printf 'export CLAUDE_SESSION_ID="%s"\n' "$session_id" >> "$CLAUDE_ENV_FILE"
fi
