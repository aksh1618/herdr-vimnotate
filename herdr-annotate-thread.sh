#!/usr/bin/env bash
set -euo pipefail
herdr="${HERDR_BIN_PATH:-herdr}"
dir="${ANNOTATE_DIR:?}"
pane="${ANNOTATE_TARGET_PANE:?}"
tab="${ANNOTATE_TAB:?}"
me="${HERDR_PANE_ID:-}"
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
reply="$dir/reply.md"
restored=""
restore() {
  [ -n "$restored" ] && return 0
  restored=1
  if [ -n "$me" ]; then
    "$herdr" pane move "$pane" --tab "$tab" --target-pane "$me" --split down --focus >/dev/null 2>&1 \
      || "$herdr" pane move "$pane" --tab "$tab" --split down --focus >/dev/null 2>&1 || true
  fi
}
cleanup() {
  restore
  rm -rf "$dir"
}
trap cleanup EXIT HUP TERM INT
rows="$(cat "$dir/rows" 2>/dev/null || echo 0)"
for _ in $(seq 1 60); do
  [ "$("$herdr" pane get "$pane" 2>/dev/null | jq -r '.result.pane.tab_id // empty')" != "$tab" ] && break
  sleep 0.05
done
for _ in $(seq 1 20); do
  [ -z "$me" ] && break
  [ "$("$herdr" pane get "$me" 2>/dev/null | jq -r '.result.pane.scroll.viewport_rows // 0')" = "$rows" ] && break
  sleep 0.05
done
printf '\033[?25l'
cat "$dir/visible.ansi"
ANNOTATE_RAW="$dir/thread.ansi" ANNOTATE_SELECTED="$dir/selected.txt" ANNOTATE_REPLY="$reply" nvim -c "luafile $script_dir/annotate-thread.lua"
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
  else
    return 1
  fi
}
agent="$("$herdr" pane get "$pane" 2>/dev/null | jq -r '.result.pane.agent // empty')"
if [ -z "${ANNOTATE_FORCE_SEND:-}" ] && [ -z "$agent" ] && [ "$(grep -c '' "$reply")" -gt 1 ]; then
  clip <"$reply" || true
  "$herdr" notification show "Annotations copied to clipboard" --body "pane $pane has no agent; multi-line reply not auto-sent" --sound none || true
  exit 0
fi
resp="$(jq -Rsc --arg pane "$pane" '{id:"annotate",method:"pane.send_input",params:{pane_id:$pane,text:(.|rtrimstr("\n")),keys:[]}}' "$reply" | socat - "UNIX-CONNECT:${HERDR_SOCKET_PATH:?}")"
if ! printf '%s' "$resp" | grep -q '"type":"ok"'; then
  clip <"$reply" || true
  "$herdr" notification show "Annotation send failed — copied to clipboard" --body "$resp" --sound none || true
fi
