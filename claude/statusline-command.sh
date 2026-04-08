#!/bin/sh
command -v jq >/dev/null 2>&1 || { echo "jq missing"; exit 0; }
input=$(cat)
user=$(whoami)
raw_host=$(hostname -s)
dir=$(basename "$(pwd)")

# 机器短名映射
case "$raw_host" in
  JackonYangs-MacBook-Pro) host="mac" ;;
  iZ25e9yr8voZ)            host="jackon.me" ;;
  aigcic-ai)               host="105" ;;
  aig-a100)                host="101" ;;
  aigcic-h3c-01)           host="116" ;;
  *) host="$raw_host" ;;
esac

used=$(echo "$input" | jq -r '(.context_window.used_percentage // 0) | floor')
five_h=$(echo "$input" | jq -r '(.rate_limits.five_hour.used_percentage // empty) | floor')
five_h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_d=$(echo "$input" | jq -r '(.rate_limits.seven_day.used_percentage // empty) | floor')
seven_d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# 当前目标：优先读 per-session .goal.<session_id>，fallback 到 worklog 核心问题
session_id=$(echo "$input" | jq -r '.session_id // empty')
problem=""
task_dir="$HOME/claude-tasks/$dir"
if [ -n "$session_id" ] && [ -f "$task_dir/.goal.$session_id" ]; then
  problem=$(head -1 "$task_dir/.goal.$session_id")
elif [ -d "$task_dir" ]; then
  latest=$(ls -t "$task_dir"/worklog-*.md 2>/dev/null | head -1)
  if [ -n "$latest" ]; then
    problem=$(grep -m1 '^- 核心问题[：:]' "$latest" 2>/dev/null | sed 's/^- 核心问题[：:][[:space:]]*//')
  fi
fi

# git branch: skip non-git, detached HEAD, and default branches
branch=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git symbolic-ref --short HEAD 2>/dev/null)
  case "$branch" in
    main|master|"") branch="" ;;
  esac
  if [ -n "$branch" ] && [ ${#branch} -gt 30 ]; then
    branch=$(printf '%.27s...' "$branch")
  fi
fi

if [ -n "$branch" ]; then
  status="${user}@${host} ${dir} [${branch}] ctx:${used}%"
else
  status="${user}@${host} ${dir} ctx:${used}%"
fi

if [ -n "$five_h" ]; then
  reset_info=""
  if [ -n "$five_h_reset" ]; then
    now=$(date +%s)
    remain=$(( five_h_reset - now ))
    if [ "$remain" -gt 0 ]; then
      hours=$(( remain / 3600 ))
      mins=$(( (remain % 3600) / 60 ))
      if [ "$hours" -gt 0 ]; then
        reset_info="${hours}h${mins}m"
      else
        reset_info="${mins}m"
      fi
    fi
  fi
  if [ -n "$reset_info" ]; then
    status="${status} 5h:${five_h}%/${reset_info}"
  else
    status="${status} 5h:${five_h}%"
  fi
fi

if [ -n "$seven_d" ]; then
  reset_7d=""
  if [ -n "$seven_d_reset" ]; then
    now=${now:-$(date +%s)}
    remain_7d=$(( seven_d_reset - now ))
    if [ "$remain_7d" -gt 0 ]; then
      days=$(( remain_7d / 86400 ))
      hours_7d=$(( (remain_7d % 86400) / 3600 ))
      if [ "$days" -gt 0 ]; then
        reset_7d="${days}d${hours_7d}h"
      else
        reset_7d="${hours_7d}h"
      fi
    fi
  fi
  if [ -n "$reset_7d" ]; then
    status="${status} 7d:${seven_d}%/${reset_7d}"
  else
    status="${status} 7d:${seven_d}%"
  fi
fi

if [ -n "$problem" ]; then
  problem=$(printf '%.50s' "$problem")
  status="${status} | ${problem}"
fi

echo "$status"
