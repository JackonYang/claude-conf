#!/usr/bin/env bash
#
# Tests for claude/hooks/validate-bash-command.sh
# Usage: bash tests/test-hooks.sh
# Exit 0 on all pass, exit 1 on any failure.

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required to run these tests"; exit 1; }

HOOK="$(cd "$(dirname "$0")/.." && pwd)/claude/hooks/validate-bash-command.sh"
PASS=0
FAIL=0

# Helper: feed a command string to the hook as JSON, return the hook output
run_hook() {
  local cmd="$1"
  jq -n --arg c "$cmd" '{"tool_input":{"command":$c}}' | bash "$HOOK"
}

assert_blocked() {
  local label="$1" cmd="$2"
  local output
  output=$(run_hook "$cmd")
  if printf '%s' "$output" | grep -q '"deny"'; then
    echo "  PASS (blocked): $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL (expected block): $label"
    echo "       cmd: $cmd"
    FAIL=$((FAIL + 1))
  fi
}

assert_allowed() {
  local label="$1" cmd="$2"
  local output
  output=$(run_hook "$cmd")
  if [[ -z "$output" ]]; then
    echo "  PASS (allowed): $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL (expected allow): $label"
    echo "       cmd: $cmd"
    echo "       output: $output"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Blocked commands ==="
assert_blocked "rm -rf /"              "rm -rf /"
assert_blocked "rm -rf / (trailing)"   "rm -rf / --no-preserve-root"
assert_blocked "sudo rm -rf /"         "sudo rm -rf /"
assert_blocked "mkfs"                  "mkfs /dev/sda1"
assert_blocked "fdisk"                 "fdisk /dev/sda"
assert_blocked "diskutil eraseDisk"    "diskutil eraseDisk JHFS+ Untitled /dev/disk0"
assert_blocked "dd if="                "dd if=/dev/zero of=/dev/sda"
assert_blocked "piped rm -rf /"        "echo foo | rm -rf /"
assert_blocked "chained rm -rf /"      "ls; rm -rf /"
assert_blocked "and-chained rm -rf /"  "true && rm -rf /"
assert_blocked "subshell rm -rf /"     "(rm -rf /)"

echo ""
echo "=== Allowed commands ==="
assert_allowed "ls"                    "ls"
assert_allowed "git status"            "git status"
assert_allowed "rm single file"        "rm file.txt"
assert_allowed "rm -rf ./build"        "rm -rf ./build"
assert_allowed "rm -rf relative dir"   "rm -rf build/"
assert_allowed "echo with rm text"     "echo 'rm -rf /'"

echo ""
echo "=== False-positive regression (quoted args) ==="
assert_allowed "gh issue --body with rm"       'gh issue create --body "do not rm -rf /"'
assert_allowed "echo double-quoted rm"         'echo "rm -rf /"'
assert_allowed "curl with dangerous body"      "curl -X POST -d 'run mkfs /dev/sda' http://example.com"

echo ""
echo "=== Edge cases ==="
assert_allowed "empty input"           ""
assert_allowed "rm -rf /tmp"           "rm -rf /tmp"
assert_blocked "unclosed quote"        'rm -rf / "'
assert_blocked "multiline dangerous"   "$(printf 'echo hello\nrm -rf /')"
assert_blocked "mixed: rm + quoted"    "rm -rf / 'safe text'"

echo ""
echo "---"
echo "Results: $PASS passed, $FAIL failed"

if (( FAIL > 0 )); then
  exit 1
fi
