#!/bin/bash
# claude-conf setup
#
# Subcommands:
#   (none)              symlink claude-conf files into ~/.claude/
#   apply [--dry-run]   symlink ~/.config/environment.d/proxy.conf and inject
#                       the proxy block into ~/.bashrc
#   verify              compare current host state vs infra/ expected; non-zero on drift

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
INFRA_DIR="$REPO_DIR/infra"
DRY_RUN=false
SUBCMD=""

# ─── arg parsing ────────────────────────────────────────
if [[ $# -gt 0 ]]; then
  case "$1" in
    apply|verify) SUBCMD="$1"; shift ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    *)          echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ─── existing symlink behavior ──────────────────────────
link() {
  local src="$REPO_DIR/$1"
  local dst="$CLAUDE_DIR/$2"

  if [[ ! -e "$src" ]]; then
    echo "SKIP  $src (not found)"
    return
  fi

  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    echo "OK    $dst -> $src"
    return
  fi

  if [[ -e "$dst" && ! -L "$dst" ]]; then
    local backup="${dst}.backup.$(date +%Y%m%d%H%M%S)"
    if $DRY_RUN; then
      echo "WOULD backup $dst -> $backup"
    else
      mv "$dst" "$backup"
      echo "BACK  $dst -> $backup"
    fi
  fi

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

run_symlink() {
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
}

# ─── infra: apply ───────────────────────────────────────
PROXY_ENV_SRC="$INFRA_DIR/environment.d/proxy.conf"
PROXY_ENV_DST="$HOME/.config/environment.d/proxy.conf"
BASHRC_SRC="$INFRA_DIR/bashrc-proxy.sh"
MARKER_BEGIN="# >>> claude-conf proxy >>>"
MARKER_END="# <<< claude-conf proxy <<<"

apply_environment_d() {
  if [[ -L "$PROXY_ENV_DST" && "$(readlink "$PROXY_ENV_DST")" == "$PROXY_ENV_SRC" ]]; then
    echo "OK    $PROXY_ENV_DST -> $PROXY_ENV_SRC"
    return
  fi
  if $DRY_RUN; then
    echo "WOULD ln -snf $PROXY_ENV_SRC $PROXY_ENV_DST"
    return
  fi
  mkdir -p "$(dirname "$PROXY_ENV_DST")"
  ln -snf "$PROXY_ENV_SRC" "$PROXY_ENV_DST"
  echo "LINK  $PROXY_ENV_DST -> $PROXY_ENV_SRC"
  # user-systemd caches environment.d at session start; reexec to pick up
  # the new file without disrupting running services.
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user daemon-reexec 2>/dev/null; then
      echo "REEXEC user systemd (refreshed environment.d cache)"
    fi
  fi
}

# Marker block body = the lines between the marker comments in BASHRC_SRC.
extract_block_body() {
  awk '
    /^# >>> claude-conf proxy >>>$/ { inside=1; next }
    /^# <<< claude-conf proxy <<<$/ { inside=0; next }
    inside { print }
  ' "$BASHRC_SRC"
}

apply_bashrc() {
  local file="$HOME/.bashrc"
  local block_body
  block_body="$(extract_block_body)"

  local existing=""
  [[ -f "$file" ]] && existing="$(cat "$file")"

  # Strip any existing block between markers, then prepend a fresh one.
  local stripped
  stripped="$(awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
    BEGIN { skip=0 }
    {
      if ($0 == b) { skip=1; next }
      if (skip && $0 == e) { skip=0; next }
      if (!skip) print
    }
  ' <<< "$existing")"

  local new_content="${MARKER_BEGIN}
${block_body}
${MARKER_END}
${stripped}"

  if [[ "$existing" == "$new_content" ]]; then
    echo "OK    $file (marker block unchanged)"
    return
  fi
  if $DRY_RUN; then
    echo "WOULD update marker block in $file"
    return
  fi
  printf '%s\n' "$new_content" > "$file"
  echo "WROTE marker block in $file"
}

run_apply() {
  $DRY_RUN && echo "(dry run mode)"
  apply_environment_d
  apply_bashrc
  echo "apply done."
}

# ─── infra: verify ──────────────────────────────────────
DRIFT=()

check_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "OK    $label"
  else
    echo "DRIFT $label"
    DRIFT+=("$label")
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/      /' || true
  fi
}

verify_environment_d() {
  if [[ -L "$PROXY_ENV_DST" && "$(readlink "$PROXY_ENV_DST")" == "$PROXY_ENV_SRC" ]]; then
    echo "OK    environment.d/proxy.conf -> $PROXY_ENV_SRC"
  else
    echo "DRIFT environment.d/proxy.conf is not the expected symlink"
    [[ -e "$PROXY_ENV_DST" ]] && echo "      current: $(readlink -f "$PROXY_ENV_DST" 2>/dev/null || echo "not a symlink")"
    DRIFT+=("environment.d symlink")
  fi
}

verify_bashrc() {
  local bashrc_path="$HOME/.bashrc"
  local expected actual
  expected="$(extract_block_body)"
  if [[ -r "$bashrc_path" ]]; then
    actual="$(awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
      $0 == b { inside=1; next }
      $0 == e { inside=0; next }
      inside { print }
    ' "$bashrc_path" 2>/dev/null)"
  else
    actual=""
  fi
  [[ -z "$actual" ]] && actual="MISSING"
  check_eq ".bashrc marker block" "$expected" "$actual"

  # Detect stray proxy exports outside the marker block (e.g. unmanaged
  # legacy from before this script existed).
  local stray
  if [[ -r "$bashrc_path" ]]; then
    stray="$(awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
      BEGIN { inside=0 }
      $0 == b { inside=1; next }
      $0 == e { inside=0; next }
      inside { next }
      /^export (HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy|NO_PROXY|no_proxy)=/ { print NR": "$0 }
    ' "$bashrc_path" 2>/dev/null)"
  else
    stray=""
  fi
  if [[ -n "$stray" ]]; then
    echo "DRIFT .bashrc has stray proxy exports outside marker block:"
    echo "$stray" | sed 's/^/      /'
    DRIFT+=(".bashrc stray exports")
  else
    echo "OK    .bashrc no stray proxy exports"
  fi
}

verify_probes() {
  # Expected value is computed from the SoT file so the script never
  # has to know the port itself.
  local expected_url
  expected_url="$(awk -F= '$1 == "HTTP_PROXY" { print $2; exit }' "$PROXY_ENV_SRC")"

  # Probe 1: clean env, source environment.d (simulates PAM/logind session)
  local p1
  p1="$(env -i HOME="$HOME" PATH="$PATH" bash -c '
    set -a
    [ -f "$HOME/.config/environment.d/proxy.conf" ] && . "$HOME/.config/environment.d/proxy.conf"
    set +a
    printf %s "${HTTP_PROXY:-MISSING}"
  ')"
  check_eq "probe[environment.d] HTTP_PROXY" "$expected_url" "$p1"

  # Probe 2: clean env, source .bashrc (simulates non-interactive ssh)
  local p2
  p2="$(env -i HOME="$HOME" PATH="$PATH" bash -c '
    [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
    printf %s "${HTTP_PROXY:-MISSING}"
  ' 2>/dev/null)"
  check_eq "probe[bashrc] HTTP_PROXY" "$expected_url" "$p2"

  # Probe 3: user-systemd manager cached env (services started via
  # `systemctl --user` see this — caught the 105/101 stale cache regression).
  if command -v systemctl >/dev/null 2>&1; then
    local p3
    p3="$(systemctl --user show-environment 2>/dev/null | awk -F= '
      $1 == "HTTP_PROXY" { print $2; exit }
    ')"
    if [[ -n "$p3" ]]; then
      check_eq "probe[systemd --user] HTTP_PROXY" "$expected_url" "$p3"
    fi
  fi
}

run_verify() {
  verify_environment_d
  verify_bashrc
  verify_probes
  if (( ${#DRIFT[@]} > 0 )); then
    echo "DRIFT (${#DRIFT[@]} items):"
    for d in "${DRIFT[@]}"; do echo "  - $d"; done
    exit 1
  fi
  echo "verify ok."
}

# ─── dispatch ───────────────────────────────────────────
case "$SUBCMD" in
  apply)  run_apply ;;
  verify) run_verify ;;
  "")     run_symlink ;;
  *)      echo "Unknown subcommand: $SUBCMD" >&2; exit 2 ;;
esac
