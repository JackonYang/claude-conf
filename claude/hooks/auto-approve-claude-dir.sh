#!/usr/bin/env bash
# PermissionRequest hook: 自动批准 ~/.claude/ 下的非 settings 文件写入
# 解决 v2.1.78+ 对 .claude/ 目录的硬保护（permissions.allow 对此无效）
# 参考：github.com/anthropics/claude-code/issues/36497
# 适用：主 agent CLI session（subagent 不走此 hook，见 issue #23983）

set -uo pipefail

# jq required for JSON parsing — skip gracefully if missing (e.g., remote servers)
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# 只自动批准 .claude/ 下的非 settings 文件
if [[ -n "$file_path" && "$file_path" == */.claude/* && "$file_path" != */.claude/settings* ]]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
fi
# 其他情况不输出，继续正常权限流程
