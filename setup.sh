#!/bin/bash
# claude-conf setup
#
# Subcommands:
#   (none)              symlink claude-conf files into ~/.claude/
#   apply [--dry-run]   render infra/ templates and write per-machine config
#   verify              compare current host state vs infra/ expected; non-zero on drift
#
# Flags:
#   --machine NAME      override hostname → machine detection (jackon.me|116|105|101)
#   --dry-run           apply: print actions without writing

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
INFRA_DIR="$REPO_DIR/infra"
DRY_RUN=false
MACHINE_OVERRIDE=""
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
    --machine)  MACHINE_OVERRIDE="$2"; shift 2 ;;
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

# ─── infra: hostname → machine ──────────────────────────
detect_machine() {
  if [[ -n "$MACHINE_OVERRIDE" ]]; then
    echo "$MACHINE_OVERRIDE"
    return
  fi
  local h
  h="$(hostname)"
  case "$h" in
    iZ25e9yr8voZ|jackon.me|jackon-me) echo "jackon.me" ;;
    aigcic-h3c-01)                    echo "116" ;;
    aigcic-ai)                        echo "105" ;;
    aig-a100)                         echo "101" ;;
    *) echo "ERROR: unknown hostname '$h' — pass --machine NAME" >&2; exit 3 ;;
  esac
}

load_machine_env() {
  local machine="$1"
  local envfile="$INFRA_DIR/per-machine/${machine}.env"
  if [[ ! -f "$envfile" ]]; then
    echo "ERROR: no env file at $envfile" >&2
    exit 3
  fi
  PROXY_PORT=""
  INSTALL_BUTLER_SYSTEMD=""
  # shellcheck disable=SC1090
  source "$envfile"
  if [[ -z "$PROXY_PORT" ]]; then
    echo "ERROR: PROXY_PORT not set in $envfile" >&2
    exit 3
  fi
}

render_template() {
  # Substitute ${PROXY_PORT} only — bash parameter expansion, no envsubst dependency.
  local src="$1"
  local content
  content="$(cat "$src")"
  printf '%s' "${content//\$\{PROXY_PORT\}/$PROXY_PORT}"
}

# ─── infra: apply primitives ────────────────────────────
write_file_if_diff() {
  local dst="$1" content="$2"
  if [[ -f "$dst" ]] && [[ "$(cat "$dst")" == "$content" ]]; then
    echo "OK    $dst (unchanged)"
    return
  fi
  if $DRY_RUN; then
    echo "WOULD write $dst"
    return
  fi
  mkdir -p "$(dirname "$dst")"
  printf '%s' "$content" > "$dst"
  echo "WROTE $dst"
}

inject_marker_block() {
  # inject_marker_block <file> <begin> <end> <block>
  # Idempotent: replaces any existing block between markers; inserts at top otherwise.
  local file="$1" begin="$2" end="$3" block="$4"
  local existing=""
  [[ -f "$file" ]] && existing="$(cat "$file")"

  local stripped
  stripped="$(awk -v b="$begin" -v e="$end" '
    BEGIN { skip=0 }
    {
      if ($0 == b) { skip=1; next }
      if (skip && $0 == e) { skip=0; next }
      if (!skip) print
    }
  ' <<< "$existing")"

  local new_content
  new_content="${begin}
${block}
${end}
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

apply_environment_d() {
  local rendered
  rendered="$(render_template "$INFRA_DIR/common/environment.d/proxy.conf")"
  write_file_if_diff "$HOME/.config/environment.d/proxy.conf" "$rendered"
}

extract_block_body() {
  # Strip the marker lines from infra/common/bashrc-proxy.sh, leaving the body.
  render_template "$INFRA_DIR/common/bashrc-proxy.sh" | awk '
    /^# >>> claude-conf proxy >>>$/ { inside=1; next }
    /^# <<< claude-conf proxy <<<$/ { inside=0; next }
    inside { print }
  '
}

strip_legacy_bashrc_proxy() {
  # The previous agent injected a 7-line block at top of ~/.bashrc:
  #   # butler user-level proxy — #24
  #   export HTTP_PROXY=...
  #   export HTTPS_PROXY=...
  #   export http_proxy=...
  #   export https_proxy=...
  #   export NO_PROXY=...
  #   export no_proxy=...
  # Strip the comment line plus any standalone PROXY exports outside our
  # marker block so they cannot shadow the marker block at source-time.
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    BEGIN { in_marker=0 }
    /^# >>> claude-conf proxy >>>$/ { in_marker=1; print; next }
    /^# <<< claude-conf proxy <<<$/ { in_marker=0; print; next }
    {
      if (in_marker) { print; next }
      if ($0 == "# butler user-level proxy — #24") next
      if ($0 ~ /^export (HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy|NO_PROXY|no_proxy)=/) next
      print
    }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

apply_bashrc() {
  local block_body
  block_body="$(extract_block_body)"
  inject_marker_block "$HOME/.bashrc" \
    "# >>> claude-conf proxy >>>" \
    "# <<< claude-conf proxy <<<" \
    "$block_body"
  if ! $DRY_RUN; then
    strip_legacy_bashrc_proxy "$HOME/.bashrc"
  fi
}

apply_crontab() {
  local header
  header="$(render_template "$INFRA_DIR/common/environment.d/proxy.conf")"
  local begin="# >>> claude-conf proxy >>>"
  local end="# <<< claude-conf proxy <<<"

  local current=""
  current="$(crontab -l 2>/dev/null || true)"

  # Strip prior marker block
  local stripped
  stripped="$(awk -v b="$begin" -v e="$end" '
    BEGIN { skip=0 }
    { if ($0 == b) { skip=1; next }
      if (skip && $0 == e) { skip=0; next }
      if (!skip) print }
  ' <<< "$current")"

  # Strip leftover bare HTTP_PROXY/etc lines from previous unmanaged installs
  stripped="$(awk '
    /^(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy|NO_PROXY|no_proxy)=/ { next }
    { print }
  ' <<< "$stripped")"

  local new_cron
  new_cron="${begin}
${header}
${end}
${stripped}"

  if [[ "$current" == "$new_cron" ]]; then
    echo "OK    crontab (unchanged)"
    return
  fi
  if $DRY_RUN; then
    echo "WOULD update crontab"
    return
  fi
  printf '%s\n' "$new_cron" | crontab -
  echo "WROTE crontab"
}

apply_systemd_drop_in() {
  if [[ "${INSTALL_BUTLER_SYSTEMD:-0}" != "1" ]]; then
    echo "SKIP  systemd drop-in (not enabled for this machine)"
    return
  fi
  # butler.service runs under the butler user-systemd instance, so the
  # drop-in only belongs in butler's home — installing it under root is
  # dead config.
  if [[ "$(id -un)" != "butler" ]]; then
    echo "SKIP  systemd drop-in (only installed for user=butler, current=$(id -un))"
    return
  fi
  local target_dir="$HOME/.config/systemd/user/butler.service.d"
  local rendered
  rendered="$(render_template "$INFRA_DIR/common/butler-service.conf")"
  write_file_if_diff "$target_dir/proxy.conf" "$rendered"
  if $DRY_RUN; then
    echo "WOULD systemctl --user daemon-reload"
    return
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user daemon-reload 2>/dev/null; then
      :
    else
      echo "WARN  systemctl --user daemon-reload failed (no user session?)"
    fi
    if systemctl --user is-active --quiet butler.service 2>/dev/null; then
      systemctl --user restart butler.service && echo "RESTART butler.service"
    fi
  fi
}

cleanup_bak() {
  local bak="$HOME/.bashrc.bak-proxy-20260408"
  if [[ -e "$bak" ]]; then
    if $DRY_RUN; then
      echo "WOULD rm $bak"
    else
      rm -f "$bak"
      echo "RM    $bak"
    fi
  fi
}

converge_proxy_env_stub() {
  # Old machines have ~/.proxy_env from the previous agent. Keep it as a compat
  # stub but rewrite to canonical PROXY_PORT to eliminate dual-config drift.
  local stub="$HOME/.proxy_env"
  if [[ ! -f "$stub" ]]; then
    return
  fi
  local content
  content="# user-level proxy compat stub — managed by claude-conf infra/
# canonical config: ~/.config/environment.d/proxy.conf
export HTTP_PROXY=http://127.0.0.1:${PROXY_PORT}
export HTTPS_PROXY=http://127.0.0.1:${PROXY_PORT}
export http_proxy=http://127.0.0.1:${PROXY_PORT}
export https_proxy=http://127.0.0.1:${PROXY_PORT}
export NO_PROXY=localhost,127.0.0.1,::1,*.aigcic.com,gitlab-sw.aigcic.com,192.168.0.0/16,172.16.0.0/12,10.0.0.0/8
export no_proxy=localhost,127.0.0.1,::1,*.aigcic.com,gitlab-sw.aigcic.com,192.168.0.0/16,172.16.0.0/12,10.0.0.0/8
"
  write_file_if_diff "$stub" "$content"
}

run_apply() {
  local machine
  machine="$(detect_machine)"
  load_machine_env "$machine"
  echo "machine: $machine"
  echo "PROXY_PORT: $PROXY_PORT"
  $DRY_RUN && echo "(dry run mode)"
  echo ""
  apply_environment_d
  apply_bashrc
  apply_crontab
  apply_systemd_drop_in
  converge_proxy_env_stub
  cleanup_bak
  echo ""
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
  local expected actual
  expected="$(render_template "$INFRA_DIR/common/environment.d/proxy.conf")"
  actual="$(cat "$HOME/.config/environment.d/proxy.conf" 2>/dev/null || echo MISSING)"
  check_eq "environment.d/proxy.conf" "$expected" "$actual"
}

verify_bashrc() {
  local expected actual begin="# >>> claude-conf proxy >>>" end="# <<< claude-conf proxy <<<"
  expected="$(extract_block_body)"
  actual="$(awk -v b="$begin" -v e="$end" '
    $0 == b { inside=1; next }
    $0 == e { inside=0; next }
    inside { print }
  ' "$HOME/.bashrc" 2>/dev/null)"
  [[ -z "$actual" ]] && actual="MISSING"
  check_eq ".bashrc marker block" "$expected" "$actual"

  # Detect stray proxy exports outside the marker block (legacy from prior agent).
  local stray
  stray="$(awk -v b="$begin" -v e="$end" '
    BEGIN { inside=0 }
    $0 == b { inside=1; next }
    $0 == e { inside=0; next }
    inside { next }
    /^export (HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy|NO_PROXY|no_proxy)=/ { print NR": "$0 }
  ' "$HOME/.bashrc" 2>/dev/null)"
  if [[ -n "$stray" ]]; then
    echo "DRIFT .bashrc has stray proxy exports outside marker block:"
    echo "$stray" | sed 's/^/      /'
    DRIFT+=(".bashrc stray exports")
  else
    echo "OK    .bashrc no stray proxy exports"
  fi
}

verify_crontab() {
  local expected actual begin="# >>> claude-conf proxy >>>" end="# <<< claude-conf proxy <<<"
  expected="$(render_template "$INFRA_DIR/common/environment.d/proxy.conf")"
  actual="$(crontab -l 2>/dev/null | awk -v b="$begin" -v e="$end" '
    $0 == b { inside=1; next }
    $0 == e { inside=0; next }
    inside { print }
  ')"
  [[ -z "$actual" ]] && actual="MISSING"
  check_eq "crontab marker block" "$expected" "$actual"
}

verify_systemd_drop_in() {
  if [[ "${INSTALL_BUTLER_SYSTEMD:-0}" != "1" ]]; then
    return
  fi
  if [[ "$(id -un)" != "butler" ]]; then
    return
  fi
  local expected actual
  expected="$(render_template "$INFRA_DIR/common/butler-service.conf")"
  actual="$(cat "$HOME/.config/systemd/user/butler.service.d/proxy.conf" 2>/dev/null || echo MISSING)"
  check_eq "systemd butler.service drop-in" "$expected" "$actual"
}

verify_probes() {
  # Verify the proxy port shows up across the contexts that matter.
  local expected_url="http://127.0.0.1:${PROXY_PORT}"

  # Probe 1: current verify-time process env
  check_eq "probe[shell] HTTP_PROXY" "$expected_url" "${HTTP_PROXY:-MISSING}"

  # Probe 2: clean env, source environment.d (simulates PAM/logind session)
  local p2
  p2="$(env -i HOME="$HOME" PATH="$PATH" bash -c '
    set -a
    [ -f "$HOME/.config/environment.d/proxy.conf" ] && . "$HOME/.config/environment.d/proxy.conf"
    set +a
    printf %s "${HTTP_PROXY:-MISSING}"
  ')"
  check_eq "probe[environment.d] HTTP_PROXY" "$expected_url" "$p2"

  # Probe 3: clean env, source .bashrc (simulates non-interactive ssh)
  local p3
  p3="$(env -i HOME="$HOME" PATH="$PATH" bash -c '
    [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
    printf %s "${HTTP_PROXY:-MISSING}"
  ' 2>/dev/null)"
  check_eq "probe[bashrc] HTTP_PROXY" "$expected_url" "$p3"

  # Probe 4: crontab marker block has the right port
  local p4
  p4="$(crontab -l 2>/dev/null | awk -F= '
    $1 == "HTTP_PROXY" { print $2; exit }
  ')"
  check_eq "probe[crontab] HTTP_PROXY" "$expected_url" "$p4"
}

run_verify() {
  local machine
  machine="$(detect_machine)"
  load_machine_env "$machine"
  echo "machine: $machine"
  echo "PROXY_PORT: $PROXY_PORT"
  echo ""
  verify_environment_d
  verify_bashrc
  verify_crontab
  verify_systemd_drop_in
  verify_probes
  echo ""
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
