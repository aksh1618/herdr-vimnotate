#!/usr/bin/env bash
set -euo pipefail
herdr="${HERDR_BIN_PATH:-herdr}"
ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"
pane="$(printf '%s' "$ctx" | jq -r '.focused_pane_id // empty')"
[ -n "$pane" ] || pane="${HERDR_ACTIVE_PANE_ID:-}"
[ -n "$pane" ] || exit 1
info="$("$herdr" pane get "$pane")"
tab="$(printf '%s' "$info" | jq -r '.result.pane.tab_id')"
workspace="$(printf '%s' "$info" | jq -r '.result.pane.workspace_id')"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
config="${HERDR_PLUGIN_CONFIG_DIR:-}/config.toml"
[ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] && [ -r "$config" ] || config=/dev/null
state_dir="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vimnotate}"
sha256() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; }
server="$(printf '%s' "${HERDR_SOCKET_PATH:-}" | sha256 | cut -c1-12)"
if [ -d "$state_dir" ]; then
  find "$state_dir" -maxdepth 1 \( -name '*.json' -o -name '*.clip' \) -mmin +10080 -delete 2>/dev/null || true
  find "$state_dir" -maxdepth 1 -name '*.json.tmp*' -mmin +60 -delete 2>/dev/null || true
  for f in "$state_dir/$server"-*.json; do
    [ -e "$f" ] || continue
    owner="$(jq -r --arg s "$server" 'select(.server == $s) | .pane // empty' "$f" 2>/dev/null || true)"
    [ -n "$owner" ] || continue
    got="$("$herdr" pane get "$owner" 2>&1 >/dev/null || true)"
    if printf '%s' "$got" | jq -e '.error.code == "pane_not_found"' >/dev/null 2>&1; then
      rm -f "$f"
    fi
  done
fi
lines="$(awk -v key=lines -f "$script_dir/config.awk" "$config")"
dir="$(mktemp -d "${TMPDIR:-/tmp}/herdr-vimnotate.XXXXXX")"
"$herdr" pane read "$pane" --source visible --format ansi >"$dir/visible.ansi" 2>/dev/null || true
"$herdr" pane read "$pane" --source recent-unwrapped --format ansi --lines "$lines" >"$dir/thread.ansi" 2>/dev/null \
  || "$herdr" pane read "$pane" --source recent --format ansi --lines "$lines" >"$dir/thread.ansi" \
  || { rm -rf "$dir"; exit 1; }
printf '%s' "$ctx" | jq -r '.selected_text // empty' >"$dir/selected.txt"
clip_hash=""
clip_max=65536
clip_tool() {
  if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-paste >/dev/null; then
    echo wl-paste
  elif command -v xclip >/dev/null; then
    echo xclip
  elif command -v xsel >/dev/null; then
    echo xsel
  elif command -v pbpaste >/dev/null; then
    echo pbpaste
  fi
}
read_clipboard() {
  local out="$1" pid size
  (umask 077 && : >"$out") || return 1
  case "$(clip_tool)" in
    wl-paste) wl-paste --no-newline --type text </dev/null >"$out" 2>/dev/null & ;;
    xclip) xclip -selection clipboard -out </dev/null >"$out" 2>/dev/null & ;;
    xsel) xsel --clipboard --output </dev/null >"$out" 2>/dev/null & ;;
    pbpaste) pbpaste </dev/null >"$out" 2>/dev/null & ;;
    *) return 1 ;;
  esac
  pid=$!
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    size="$(wc -c <"$out")"
    [ "$size" -le "$clip_max" ] || break
    sleep 0.025
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi
  wait "$pid" 2>/dev/null || return 1
  size="$(wc -c <"$out")"
  [ "$size" -gt 0 ] && [ "$size" -le "$clip_max" ]
}
if [ ! -s "$dir/selected.txt" ]; then
  if read_clipboard "$dir/clipboard.txt"; then
    clip_hash="$(sha256 <"$dir/clipboard.txt" | cut -c1-64)"
    if [ "$(cat "$state_dir/$server.clip" 2>/dev/null || true)" = "$clip_hash" ]; then
      clip_hash=""
    fi
  fi
  [ -n "$clip_hash" ] || rm -f "$dir/clipboard.txt"
fi
tabs="$("$herdr" tab list --workspace "$workspace" 2>/dev/null)" || tabs=""
tab_position="$(printf '%s' "$tabs" | jq -r --arg t "$tab" '[.result.tabs[].tab_id] | index($t) // empty | . + 1' 2>/dev/null)" || tab_position=""
tab_label="$(printf '%s' "$tabs" | jq -r --arg t "$tab" '.result.tabs[] | select(.tab_id == $t) | .label' 2>/dev/null)" || tab_label=""
rename=false
if [ -n "$tab_position" ] && [ "$tab_label" != "$tab_position" ]; then
  rename=true
fi
zoomed="$("$herdr" pane layout --pane "$pane" 2>/dev/null | jq -r '.result.layout.zoomed // false')" || zoomed=false
resp="$("$herdr" plugin pane open --plugin "${HERDR_PLUGIN_ID:?}" --entrypoint vimnotate --placement tab --workspace "$workspace" --no-focus \
  --env "VIMNOTATE_DIR=$dir" --env "VIMNOTATE_TARGET_PANE=$pane" --env "VIMNOTATE_TAB=$tab" --env "VIMNOTATE_ZOOMED=$zoomed" \
  --env "VIMNOTATE_TAB_RENAME=$rename" --env "VIMNOTATE_TAB_LABEL=$tab_label" --env "VIMNOTATE_CLIP_HASH=$clip_hash")" || { rm -rf "$dir"; exit 1; }
new="$(printf '%s' "$resp" | jq -r '.result.plugin_pane.pane.pane_id // empty')"
[ -n "$new" ] || { rm -rf "$dir"; exit 1; }
if [ "$zoomed" = true ]; then
  "$herdr" pane zoom "$pane" --off >/dev/null
fi
if ! "$herdr" pane move "$new" --tab "$tab" --target-pane "$pane" --split down --focus >/dev/null; then
  [ "$zoomed" != true ] || "$herdr" pane zoom "$pane" --on >/dev/null || true
  exit 1
fi
"$herdr" pane move "$pane" --new-tab --workspace "$workspace" --no-focus --label "${tab_label:+$tab_label }[parked by vimnotate]" >/dev/null
