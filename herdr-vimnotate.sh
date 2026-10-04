#!/usr/bin/env bash
set -euo pipefail
herdr="${HERDR_BIN_PATH:-herdr}"
dir="${VIMNOTATE_DIR:?}"
pane="${VIMNOTATE_TARGET_PANE:?}"
tab="${VIMNOTATE_TAB:?}"
zoomed="${VIMNOTATE_ZOOMED:-false}"
tab_label="${VIMNOTATE_TAB_LABEL:-}"
tab_rename="${VIMNOTATE_TAB_RENAME:-false}"
me="${HERDR_PANE_ID:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
reply="$dir/reply.md"
config="${HERDR_PLUGIN_CONFIG_DIR:-}/config.toml"
[ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] && [ -r "$config" ] || config=/dev/null
conf() { awk -v key="$1" -f "$script_dir/config.awk" "$config"; }
view="$(conf view)"
action_bar="$(conf action_bar)"
restore_on="$(conf restore)"
force_send="$(conf force_send)"
key_comment="$(conf keys.comment)"
key_delete="$(conf keys.delete)"
key_looks_good="$(conf keys.looks_good)"
sha256() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; }
server="$(printf '%s' "${HERDR_SOCKET_PATH:-}" | sha256 | cut -c1-12)"
state="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vimnotate}/$server-$(printf '%s' "$pane" | tr -c 'A-Za-z0-9_-' '_').json"
restored=""
keep=""
parked=""
renamed=""
tab_of() { "$herdr" pane get "$1" 2>/dev/null | jq -r '.result.pane.tab_id // empty'; }
label_of() { "$herdr" tab get "$tab" 2>/dev/null | jq -er '.result.tab.label'; }
unrename() {
  [ -n "$renamed" ] || return 0
  local current
  for _ in 1 2 3; do
    if current="$(label_of)"; then
      [ "$current" != "$renamed" ] || "$herdr" tab rename "$tab" "$tab_label" >/dev/null 2>&1 || { sleep 0.1; continue; }
      renamed=""
      return 0
    fi
    sleep 0.1
  done
}
zoomed_at() { [ "$("$herdr" pane layout --pane "$1" 2>/dev/null | jq -r '.result.layout.zoomed // false')" = true ]; }
restore() {
  [ -n "$restored" ] && return 0
  restored=1
  local rezoom=false
  if [ -n "$me" ]; then
    if zoomed_at "$me"; then
      rezoom=true
      "$herdr" pane zoom "$me" --off >/dev/null 2>&1 || true
    fi
    if zoomed_at "$pane"; then
      "$herdr" pane zoom "$pane" --off >/dev/null 2>&1 || true
    fi
    "$herdr" pane move "$pane" --tab "$tab" --target-pane "$me" --split down --focus >/dev/null 2>&1 \
      || "$herdr" pane move "$pane" --tab "$tab" --split down --focus >/dev/null 2>&1 || true
  fi
  if [ "$rezoom" = true ] && [ "$(tab_of "$pane")" = "$tab" ]; then
    "$herdr" pane move "$me" --new-tab --no-focus >/dev/null 2>&1 || true
    if [ "$(tab_of "$me")" != "$tab" ]; then
      "$herdr" pane zoom "$pane" --on >/dev/null 2>&1 || true
    fi
  fi
  "$herdr" pane resize --pane "$pane" --direction right --amount 0 >/dev/null 2>&1 || true
}
cleanup() {
  unrename
  restore
  [ -n "$keep" ] || rm -rf "$dir"
}
trap cleanup EXIT HUP TERM INT
for _ in $(seq 1 60); do
  if [ "$(tab_of "$pane")" != "$tab" ]; then
    parked=1
    break
  fi
  sleep 0.05
done
if [ -n "$parked" ] && [ "$tab_rename" = true ] && [ "$(label_of)" = "$tab_label" ] \
  && "$herdr" tab rename "$tab" "vimnotate${tab_label:+: $tab_label}" >/dev/null 2>&1; then
  renamed="vimnotate${tab_label:+: $tab_label}"
fi
printf '\033[?1049h\033[?25l'
before="$(stty size 2>/dev/null || true)"
if [ "$zoomed" = true ] && [ -n "$me" ] && [ -n "$parked" ]; then
  "$herdr" pane zoom "$me" --on >/dev/null 2>&1 || true
fi
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
  VIMNOTATE_VIEW="$view" VIMNOTATE_ACTION_BAR="$action_bar" VIMNOTATE_RESTORE="$restore_on" \
  VIMNOTATE_KEY_COMMENT="$key_comment" VIMNOTATE_KEY_DELETE="$key_delete" VIMNOTATE_KEY_LOOKS_GOOD="$key_looks_good" nvim -i NONE -c "luafile $script_dir/vimnotate.lua"
printf '\033[2J\033[H'
unrename
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
if [ "$force_send" != true ] && [ -z "$agent" ] && [ "$(grep -c '' "$reply")" -gt 1 ]; then
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
