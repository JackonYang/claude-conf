#!/bin/bash
# claude-conf setup — symlink config files to ~/.claude/
# Usage: ./setup.sh [--dry-run]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    *)          echo "Unknown option: $1"; exit 1 ;;
  esac
done

link() {
  local src="$REPO_DIR/$1"
  local dst="$CLAUDE_DIR/$2"

  if [[ ! -e "$src" ]]; then
    echo "SKIP  $src (not found)"
    return
  fi

  # Already the correct symlink
  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    echo "OK    $dst -> $src"
    return
  fi

  # Back up existing real file/directory
  if [[ -e "$dst" && ! -L "$dst" ]]; then
    local backup="${dst}.backup.$(date +%Y%m%d%H%M%S)"
    if $DRY_RUN; then
      echo "WOULD backup $dst -> $backup"
    else
      mv "$dst" "$backup"
      echo "BACK  $dst -> $backup"
    fi
  fi

  # Remove stale symlink
  if [[ -L "$dst" ]]; then
    if $DRY_RUN; then
      echo "WOULD rm old symlink $dst"
    else
      rm "$dst"
    fi
  fi

  mkdir -p "$(dirname "$dst")"

  if $DRY_RUN; then
    echo "WOULD $dst -> $src"
  else
    ln -s "$src" "$dst"
    echo "LINK  $dst -> $src"
  fi
}

echo "claude-conf setup $(date +%Y-%m-%d)"
$DRY_RUN && echo "(dry run mode)"
echo ""

link "claude/CLAUDE.md"              "CLAUDE.md"
link "claude/settings.json"          "settings.json"
link "claude/statusline-command.sh"  "statusline-command.sh"
link "claude/hooks"                  "hooks"
link "claude/skills"                 "skills"

echo ""
echo "done."
