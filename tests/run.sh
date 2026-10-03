#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
plugin="$(dirname "$here")"
fx="$here/fixtures"
work="$(mktemp -d "${TMPDIR:-/tmp}/vimnotate-tests.XXXXXX")"
trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT
out="$work/out"
: >"$out"
fails=0
passes=0

check() {
  if eval "$1"; then
    echo "ok shell: $2" >>"$out"
  else
    echo "FAIL shell: $2" >>"$out"
  fi
}

vn() {
  local cap="$1" state="$2" name="$3"
  rm -f "$work/reply.md" "$work/note.md"
  VIMNOTATE_RAW="$fx/$cap" VIMNOTATE_STATE="$state" VIMNOTATE_TARGET_PANE=p1 VIMNOTATE_SERVER="${SERVER:-srvA}" \
    VIMNOTATE_REPLY="$work/reply.md" VIMNOTATE_SELECTED="${SELECTED:-/dev/null}" VIMNOTATE_TEST_OUT="$out" \
    timeout 20 nvim --clean --headless -i NONE --cmd "${PRE:-}" -c "luafile $plugin/vimnotate.lua" -c "luafile $here/lib.lua" \
    -c "lua T.run('$here/cases.lua', '$name')" >>"$work/nvim.log" 2>&1
  if ! grep -q "^END $name\$" "$out"; then
    echo "FAIL $name: did not finish (rc=$?)" >>"$out"
  fi
}

st="$work/state"
mkdir -p "$st"

vn rep_a.txt "$st/rep.json" rep_save
vn rep_a.txt "$st/rep.json" rep_same
vn rep_b.txt "$st/rep.json" rep_shifted
vn lw_a.txt "$st/lw.json" lw_save
vn lw_b.txt "$st/lw.json" lw_missing
vn short_a.txt "$st/short.json" short_save
vn short_b.txt "$st/short.json" short_missing
vn short_a.txt "$st/short.json" short_back
vn emo_a.txt "$st/emo.json" emo_save
vn emo_b.txt "$st/emo.json" emo_missing
mkdir -p "$work/ro" && chmod 555 "$work/ro"
vn rep_a.txt "$work/ro/sub/x.json" ro_send
check '[ -s "$work/reply.md" ] && [ ! -e "$work/ro/sub" ]' "unwritable state dir still writes reply.md"
chmod 755 "$work/ro"
printf '{"pane":"p1","items":[null]}' >"$st/c1.json"
vn rep_a.txt "$st/c1.json" corrupt_unversioned
printf 'not json' >"$st/c2.json"
vn rep_a.txt "$st/c2.json" corrupt_unversioned
printf '{"version":1,"server":"srvA","pane":"p1","items":[null,5,"x",{"text":"Now the tests.","kind":"good","linewise":true},{"kind":"bogus","text":"Done."}]}' >"$st/c3.json"
vn rep_a.txt "$st/c3.json" corrupt_entries
for _ in 1 2 3; do PRE='let g:vimnotate_restore = v:false' vn rep_a.txt "$st/off.json" off_add; done
vn rep_a.txt "$st/off.json" off_count
SERVER=srvB vn rep_a.txt "$st/rep.json" server_mismatch
vn rep_a.txt "$st/rep.json" rep_same
vn rep_a.txt "$work/xdg/a/b/x.json" perms_save
check '[ "$(stat -c %a "$work/xdg/a/b")" = 700 ] && [ "$(stat -c %a "$work/xdg/a/b/x.json")" = 600 ]' "state dir 0700, file 0600"
check '[ -z "$(find "$work/xdg/a/b" -name "*.tmp*")" ]' "no tmp file left behind"
vn ops.txt "$st/rk.json" rekind_save
vn ops.txt "$st/rk.json" rekind
vn ops.txt "$st/fmt.json" format
check 'cmp -s "$work/reply.md" "$fx/format.expected"' "reply.md bytes"
vn ops.txt "" operators
vn ops.txt "" visual
vn ops.txt "" dot_repeat
vn ops.txt "" undo_redo
vn ops.txt "" compose_highlight
SELECTED="$fx/sel.txt" vn ops.txt "" anchor_highlight
vn ops.txt "" hover_sent
vn ops.txt "" no_repeat_provider
vn ops.txt "" note_toggle
check '[ "$(cat "$work/reply.md")" = "$(printf "line one\nline two!\n\n> line five\n\nLooks good.")" ]' "note sent first, with the popup open"
vn ops.txt "" note_empty
check '[ "$(head -c 1 "$work/reply.md")" = ">" ]' "blank note sends nothing"
vn ops.txt "" note_none
check '[ ! -e "$work/reply.md" ]' "empty note and no annotations write no reply"
SELECTED="$fx/missing.txt" vn ops.txt "" note_fallback
check '[ "$(cat "$work/reply.md")" = "$(printf "> not in the thread\n> second line\n\nreply here")" ]' "copy-mode fallback note is sent"
vn ops.txt "" note_cancel
check '[ ! -e "$work/reply.md" ]' ":Cancel discards the note"
vn ops.txt "" note_layout
vn ops.txt "" note_focus
vn ops.txt "" note_title_insert
vn ops.txt "" note_marker
vn ops.txt "" pin_rail
vn ops.txt "" pin_alone
vn ops.txt "" pin_nav
vn ops.txt "" popup_undo
vn ops.txt "" mouse_scrolloff_bar
vn ops.txt "" mouse_scrolloff_plain
vn ops.txt "" mouse_scrolloff_restore
mkdir -p "$work/undo"
PRE="set undofile undodir=$work/undo" vn ops.txt "" no_undofile
check '[ -s "$work/reply.md" ] && [ -z "$(ls -A "$work/undo")" ]' "no undo file written"
PRE="set rtp+=$fx/provider | lua local r = require('nvim-treesitter-textobjects.repeatable_move') vim.keymap.set('n', ';', r.repeat_last_move_next) vim.keymap.set('n', ',', r.repeat_last_move_previous) vim.keymap.set('n', 'f', r.builtin_f_expr, { expr = true })" vn ops.txt "" repeat_provider

hk="$work/hk"
mkdir -p "$hk/vimnotate" "$hk/bin"
d="$hk/vimnotate"
srv="$(printf '%s' /tmp/sockA | sha256sum | cut -c1-12)"
for p in p_live p_dead p_broken p_stdout; do
  printf '{"version":1,"server":"%s","pane":"%s","items":[]}' "$srv" "$p" >"$d/$srv-$p.json"
done
printf '{"version":1,"server":"other","pane":"p_dead","items":[]}' >"$d/other-p_dead.json"
printf '{}' >"$d/old.json"
touch -d '10081 minutes ago' "$d/old.json"
printf '{}' >"$d/young.json"
touch -d '10079 minutes ago' "$d/young.json"
printf '{}' >"$d/a.json.tmp.1"
touch -d '61 minutes ago' "$d/a.json.tmp.1"
printf '{}' >"$d/b.json.tmp.2"
touch -d '59 minutes ago' "$d/b.json.tmp.2"
cat >"$hk/bin/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "pane get p_live" | "pane get p1") echo '{"result":{"pane":{"pane_id":"'"$3"'","tab_id":"t1","workspace_id":"w1"}}}' ;;
  "pane get p_broken") echo '{"error":"protocol mismatch"}' >&2; exit 1 ;;
  "pane get p_stdout") echo '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  "pane get "*) echo '{"error":{"code":"pane_not_found"}}' >&2; exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$hk/bin/herdr"
HERDR_SOCKET_PATH=/tmp/sockA XDG_STATE_HOME="$hk" HERDR_BIN_PATH="$hk/bin/herdr" HERDR_PLUGIN_ID=x \
  HERDR_PLUGIN_CONTEXT_JSON='{"focused_pane_id":"p1"}' TMPDIR="$hk" "$plugin/open.sh" >/dev/null 2>&1
left="$(cd "$d" && ls | sort | tr '\n' ' ')"
want="$(printf '%s\n' "$srv-p_broken.json" "$srv-p_live.json" "$srv-p_stdout.json" b.json.tmp.2 other-p_dead.json young.json | sort | tr '\n' ' ')"
check '[ "$left" = "$want" ]' "open.sh housekeeping keeps exactly: $want (got: $left)"
check '[ -z "$(find "$hk" -maxdepth 1 -name "herdr-vimnotate.*")" ]' "open.sh removes its temp dir when the pane read fails"

empty() { awk -f "$plugin/composer-empty.awk"; }
check 'printf "some output\n────────\n❯ \n────────\n  ? for shortcuts\n" | empty' "composer-empty: lone prompt between rules"
check 'printf "────────\n❯\n────────\n" | empty' "composer-empty: prompt without trailing space"
check '! printf "────────\n❯ half typed\n────────\n" | empty' "composer-empty: typed text"
check '! printf "────────\n❯ line one\n  line two\n────────\n" | empty' "composer-empty: multi-line draft"
check '! printf "plain shell\n$ \n" | empty' "composer-empty: no composer"
check '! printf "────────\n❯ \n────────\nmore\n────────\nx\n────────\n" | empty' "composer-empty: last rule pair decides"
for a in claude codex pi; do
  check 'empty <"$fx/composer-$a-empty.ansi"' "composer-empty: $a, empty"
  for st in typed multi; do
    check '! empty <"$fx/composer-$a-$st.ansi"' "composer-empty: $a, $st draft"
  done
done
check '! empty <"$fx/composer-codex-blankfirst.ansi"' "composer-empty: codex draft below a blank first line"
check 'printf "────────\n❯ \033[2mTry something\033[0m\n────────\n" | empty' "composer-empty: faint placeholder"
check 'printf "────────\n❯ \033[0;2mTry\033[22m\033[2m more\033[m\n────────\n" | empty' "composer-empty: combined faint params"
check '! printf "────────\n❯ \033[2mTry\033[22m typed\n────────\n" | empty' "composer-empty: 22 ends faint"
check '! printf "────────\n❯ \033[1;38;2;2;2;2mtyped\033[0m\n────────\n" | empty' "composer-empty: truecolor 2s are not faint"
check 'printf "────────\n❯ \033[1;2;38;2;9;9;9mhint\033[0m\n────────\n" | empty' "composer-empty: faint among colour params"
check '! printf "\033[48;5;236m› \033[2mAsk\033[0m\n\033[48;5;236m  typed\033[0m\nfooter\n" | empty' "composer-empty: codex continuation inside the shaded block"
check 'printf "\033[48;5;236m› \033[2mAsk\033[0m\n\033[48;5;236m \033[0m\nfooter\n" | empty' "composer-empty: codex footer outside the shaded block"
check '! printf "› \033[2mAsk\033[0m\nfooter\n" | empty' "composer-empty: unshaded codex prompt runs to the next blank"
check '! printf "› done\n────────\n\n────────\n› Ask\n" | empty' "composer-empty: prompt below the last rule wins"

while IFS= read -r line; do
  case "$line" in
    ok\ *) passes=$((passes + 1)) ;;
    FAIL\ *) fails=$((fails + 1)); printf '%s\n' "$line" ;;
    "  "*) printf '%s\n' "$line" ;;
  esac
done <"$out"
if grep -qi 'error' "$work/nvim.log"; then
  fails=$((fails + 1))
  grep -i 'error' "$work/nvim.log" | head -5
fi
echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
