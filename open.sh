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
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/vimnotate"
server="$(printf '%s' "${HERDR_SOCKET_PATH:-}" | sha256sum | cut -c1-12)"
if [ -d "$state_dir" ]; then
  find "$state_dir" -maxdepth 1 -name '*.json' -mmin +10080 -delete 2>/dev/null || true
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
lines="${VIMNOTATE_LINES:-1000}"
dir="$(mktemp -d "${TMPDIR:-/tmp}/herdr-vimnotate.XXXXXX")"
"$herdr" pane read "$pane" --source visible --format ansi >"$dir/visible.ansi" 2>/dev/null || true
"$herdr" pane read "$pane" --source recent-unwrapped --format ansi --lines "$lines" >"$dir/thread.ansi" 2>/dev/null \
  || "$herdr" pane read "$pane" --source recent --format ansi --lines "$lines" >"$dir/thread.ansi" \
  || { rm -rf "$dir"; exit 1; }
printf '%s' "$ctx" | jq -r '.selected_text // empty' >"$dir/selected.txt"
resp="$("$herdr" plugin pane open --plugin "${HERDR_PLUGIN_ID:?}" --entrypoint vimnotate --placement tab --workspace "$workspace" --no-focus \
  --env "VIMNOTATE_DIR=$dir" --env "VIMNOTATE_TARGET_PANE=$pane" --env "VIMNOTATE_TAB=$tab")" || { rm -rf "$dir"; exit 1; }
new="$(printf '%s' "$resp" | jq -r '.result.plugin_pane.pane.pane_id // empty')"
[ -n "$new" ] || { rm -rf "$dir"; exit 1; }
"$herdr" pane move "$new" --tab "$tab" --target-pane "$pane" --split down --focus >/dev/null
"$herdr" pane move "$pane" --new-tab --workspace "$workspace" --no-focus --label "vimnotate · parked" >/dev/null
