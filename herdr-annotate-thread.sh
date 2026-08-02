#!/usr/bin/env bash
set -euo pipefail
pane="${ANNOTATE_TARGET_PANE:-${HERDR_ACTIVE_PANE_ID:?no target pane}}"
lines="${ANNOTATE_LINES:-2000}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/herdr-annotate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT HUP TERM INT
raw="$tmp/thread.ansi"
reply="$tmp/reply.md"
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
herdr pane read "$pane" --source recent-unwrapped --format ansi --lines "$lines" >"$raw" 2>/dev/null \
  || herdr pane read "$pane" --source recent --format ansi --lines "$lines" >"$raw"
printf '\033[?25l'
cat "$raw"
ANNOTATE_RAW="$raw" ANNOTATE_REPLY="$reply" nvim -c "luafile $script_dir/annotate-thread.lua"
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
agent="$(herdr pane get "$pane" 2>/dev/null | jq -r '.result.pane.agent // empty')"
if [ -z "${ANNOTATE_FORCE_SEND:-}" ] && [ -z "$agent" ] && [ "$(grep -c '' "$reply")" -gt 1 ]; then
  clip <"$reply" || true
  herdr notification show "Annotations copied to clipboard" --body "pane $pane has no agent; multi-line reply not auto-sent" --sound none || true
  exit 0
fi
resp="$(jq -Rsc --arg pane "$pane" '{id:"annotate",method:"pane.send_input",params:{pane_id:$pane,text:(.|rtrimstr("\n")),keys:[]}}' "$reply" | socat - "UNIX-CONNECT:${HERDR_SOCKET_PATH:?}")"
if ! printf '%s' "$resp" | grep -q '"type":"ok"'; then
  clip <"$reply" || true
  herdr notification show "Annotation send failed — copied to clipboard" --body "$resp" --sound none || true
fi
