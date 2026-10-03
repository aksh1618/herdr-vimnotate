#!/usr/bin/env bash
set -euo pipefail
herdr="${HERDR_BIN_PATH:-herdr}"
dir="${VIMNOTATE_DIR:?}"
pane="${VIMNOTATE_TARGET_PANE:?}"
tab="${VIMNOTATE_TAB:?}"
me="${HERDR_PANE_ID:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
reply="$dir/reply.md"
config="${HERDR_PLUGIN_CONFIG_DIR:-}/config.toml"
[ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] && [ -r "$config" ] || config=/dev/null
conf() { awk -v key="$1" -f "$script_dir/config.awk" "$config"; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; }
server="$(printf '%s' "${HERDR_SOCKET_PATH:-}" | sha256 | cut -c1-12)"
state="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vimnotate}/$server-$(printf '%s' "$pane" | tr -c 'A-Za-z0-9_-' '_').json"
restored=""
keep=""
restore() {
  [ -n "$restored" ] && return 0
  restored=1
  if [ -n "$me" ]; then
    "$herdr" pane move "$pane" --tab "$tab" --target-pane "$me" --split down --focus >/dev/null 2>&1 \
      || "$herdr" pane move "$pane" --tab "$tab" --split down --focus >/dev/null 2>&1 || true
  fi
  "$herdr" pane resize --pane "$pane" --direction right --amount 0 >/dev/null 2>&1 || true
}
cleanup() {
  restore
  [ -n "$keep" ] || rm -rf "$dir"
}
trap cleanup EXIT HUP TERM INT
for _ in $(seq 1 60); do
  [ "$("$herdr" pane get "$pane" 2>/dev/null | jq -r '.result.pane.tab_id // empty')" != "$tab" ] && break
  sleep 0.05
done
printf '\033[?1049h\033[?25l'
before="$(stty size 2>/dev/null || true)"
for _ in 1 2; do
  [ -n "$me" ] || break
  "$herdr" pane resize --pane "$me" --direction right --amount 0 >/dev/null 2>&1 || true
  for _ in $(seq 1 8); do
    [ "$(stty size 2>/dev/null || true)" != "$before" ] && break 2
    sleep 0.025
  done
done
printf '\033[2J\033[H'
cat "$dir/visible.ansi"
VIMNOTATE_RAW="$dir/thread.ansi" VIMNOTATE_SELECTED="$dir/selected.txt" VIMNOTATE_REPLY="$reply" VIMNOTATE_STATE="$state" VIMNOTATE_SERVER="$server" \
  VIMNOTATE_VIEW="$(conf view)" VIMNOTATE_ACTION_BAR="$(conf action_bar)" VIMNOTATE_RESTORE="$(conf restore)" nvim -i NONE -c "luafile $script_dir/vimnotate.lua"
printf '\033[2J\033[H'
restore
[ -f "$reply" ] || exit 0
grep -q '[^[:space:]]' "$reply" || exit 0
clip() {
  if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null; then
    wl-copy
  elif command -v xclip >/dev/null; then
    xclip -selection clipboard -in
  elif command -v xsel >/dev/null; then
    xsel --clipboard --input
  elif command -v pbcopy >/dev/null; then
    pbcopy
  else
    return 1
  fi
}
fallback() {
  if clip <"$reply"; then
    "$herdr" notification show "$1, copied to clipboard" --body "$2" --sound none || true
  else
    keep=1
    "$herdr" notification show "$1, saved to $reply" --body "$2" --sound none || true
  fi
}
agent="$("$herdr" pane get "$pane" 2>/dev/null | jq -r '.result.pane.agent // empty')" || agent=""
if [ "$(conf force_send)" != true ] && [ -z "$agent" ] && [ "$(grep -c '' "$reply")" -gt 1 ]; then
  fallback "Annotations not sent" "pane $pane has no agent; multi-line reply not auto-sent"
  exit 0
fi
empty=false
if "$herdr" pane read "$pane" --source visible --format ansi 2>/dev/null \
  | awk -f "$script_dir/composer-empty.awk"; then
  empty=true
fi
resp="$(jq -Rsc --arg pane "$pane" --argjson empty "$empty" '{id:"vimnotate",method:"pane.send_input",params:{pane_id:$pane,text:(rtrimstr("\n") | (if $empty then "" elif test("\n") then "\n\n" else " " end) + .),keys:[]}}' "$reply" | socat - "UNIX-CONNECT:${HERDR_SOCKET_PATH:?}")" || resp="${resp:-no response from herdr}"
if ! printf '%s' "$resp" | grep -q '"type":"ok"'; then
  fallback "Annotation send failed" "$resp"
fi
