#!/usr/bin/env bash
set -uo pipefail
unset HERDR_PLUGIN_CONFIG_DIR HERDR_PLUGIN_STATE_DIR VIMNOTATE_VIEW VIMNOTATE_ACTION_BAR VIMNOTATE_RESTORE VIMNOTATE_KEY_COMMENT VIMNOTATE_KEY_DELETE VIMNOTATE_KEY_LOOKS_GOOD
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
for _ in 1 2 3; do VIMNOTATE_RESTORE=false vn rep_a.txt "$st/off.json" off_add; done
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
vn ops.txt "" mode_cue
PRE="hi VimnotateMode guibg=#123456" vn ops.txt "" mode_cue_override
vn ops.txt "" pin_rail
vn ops.txt "" pin_alone
vn ops.txt "" pin_nav
vn ops.txt "" popup_undo
vn ops.txt "" compose_full_row
vn ops.txt "" compose_box_wrap
vn ops.txt "" wrap_matches_nvim
vn ops.txt "" mouse_scrolloff_bar
vn ops.txt "" mouse_scrolloff_plain
vn ops.txt "" mouse_scrolloff_restore
vn ops.txt "" hint_bar
vn ops.txt "" hint_show
vn ops.txt "" item_shown_edges
mkdir -p "$work/undo"
PRE="set undofile undodir=$work/undo" vn ops.txt "" no_undofile
check '[ -s "$work/reply.md" ] && [ -z "$(ls -A "$work/undo")" ]' "no undo file written"
PRE="set rtp+=$fx/provider | lua local r = require('nvim-treesitter-textobjects.repeatable_move') vim.keymap.set('n', ';', r.repeat_last_move_next) vim.keymap.set('n', ',', r.repeat_last_move_previous) vim.keymap.set('n', 'f', r.builtin_f_expr, { expr = true })" vn ops.txt "" repeat_provider
vn ops.txt "" config_defaults
VIMNOTATE_VIEW=rail VIMNOTATE_ACTION_BAR=never vn ops.txt "" config_set
vn ops.txt "" keys_resolve
VIMNOTATE_KEY_LOOKS_GOOD=x vn ops.txt "" keys_warning
VIMNOTATE_KEY_COMMENT= VIMNOTATE_KEY_LOOKS_GOOD=y vn ops.txt "" keys_empty
VIMNOTATE_KEY_COMMENT=w vn ops.txt "" keys_w
VIMNOTATE_KEY_COMMENT=m VIMNOTATE_KEY_DELETE=s VIMNOTATE_KEY_LOOKS_GOOD=y vn ops.txt "" keys_custom
PRE="lua vim.keymap.set({'x', 'o'}, 'af', 'iw') vim.keymap.set('n', 'ab', '<Nop>')" VIMNOTATE_KEY_COMMENT=i VIMNOTATE_KEY_LOOKS_GOOD=a vn ops.txt "" keys_prefix

cf="$work/cf"
mkdir -p "$cf"
cfg() { awk -v key="$1" -f "$plugin/config.awk" "$2"; }
cfgall() { for k in view action_bar restore lines force_send keys.comment keys.delete keys.looks_good; do printf '%s ' "$(cfg "$k" "$1")"; done; }
defaults="inline always true 1000 false c d p "
cat >"$cf/good.toml" <<'EOF'
# vimnotate

view = "rail"   # side rail
action_bar="mouse"
  restore = false
lines = 250 # fewer
force_send = true
unknown = "x"

[keys]  # operators
comment = "m"  # mine
delete="#"
looks_good = "a"
EOF
check '[ "$(cfgall "$cf/good.toml")" = "rail mouse false 250 true m # a " ]' "config: every key, comments, blank lines, unknown key"
printf 'view = "auto"\r\nlines = 42\r\n' >"$cf/crlf.toml"
check '[ "$(cfgall "$cf/crlf.toml")" = "auto always true 42 false c d p " ]' "config: CRLF line endings"
cat >"$cf/bad.toml" <<'EOF'
view = "sideways"
action_bar = never
restore = "false"
lines = 0
force_send = yes
view = "rail
view = "off" trailing
lines = 12abc
lines = -5
lines = "500"
lines = 1001
lines = 4294967296
lines = 01
keys.comment = m
keys.delete = 'x'
keys.looks_good = "\a"
keys = { comment = "z" }
comment = "z"
[keys]
comment = z
good = "z"
view = "rail"
[keys.extra]
comment = "z"
[[keys]]
delete = "z"
[keys.]
looks_good = "z"
= "rail"
EOF
check '[ "$(cfgall "$cf/bad.toml")" = "$defaults" ]' "config: invalid values fall back to defaults"
printf 'lines = 1\n' >"$cf/min.toml"
printf 'lines = 1000\n' >"$cf/max.toml"
printf 'lines = 1\nlines = 1001\n' >"$cf/over.toml"
check '[ "$(cfg lines "$cf/min.toml") $(cfg lines "$cf/max.toml") $(cfg lines "$cf/over.toml")" = "1 1000 1" ]' "config: lines accepts 1 to 1000 only"
printf '[keys]\nlooks_good = "aa"\ndelete = "x"\n' >"$cf/keys.toml"
check '[ "$(cfg keys.looks_good "$cf/keys.toml") $(cfg keys.delete "$cf/keys.toml")" = "aa x" ]' "config: a quoted key passes through for nvim to check"
printf 'keys.comment = "m"\nkeys . delete = "s"\nkeys\t.\tlooks_good = "y"\n' >"$cf/dotted.toml"
check '[ "$(cfg keys.comment "$cf/dotted.toml") $(cfg keys.delete "$cf/dotted.toml") $(cfg keys.looks_good "$cf/dotted.toml")" = "m s y" ]' "config: dotted keys outside a table, spaces around the dot"
printf '[ keys . sub ]\ncomment = "m"\n' >"$cf/spacedsub.toml"
check '[ "$(cfg keys.comment "$cf/spacedsub.toml")" = c ]' "config: a spaced subtable header is still a subtable"
printf ' [ keys ] # ops\ncomment = "m"\n[other]\ndelete = "s"\n[keys]\ndelete = "y"\n[keys.sub]\nlooks_good = "z"\n' >"$cf/reopen.toml"
check '[ "$(cfg keys.comment "$cf/reopen.toml") $(cfg keys.delete "$cf/reopen.toml") $(cfg keys.looks_good "$cf/reopen.toml")" = "m y p" ]' "config: spaced header, a reopened [keys], other tables and subtables ignored"
printf 'view = "off"\n[keys]\ncomment = "m"\nview = "rail"\n' >"$cf/scoped.toml"
check '[ "$(cfg view "$cf/scoped.toml") $(cfg keys.comment "$cf/scoped.toml")" = "off m" ]' "config: a top-level key under [keys] is ignored"
printf 'keys = { comment = "m" }\n' >"$cf/inline.toml"
check '[ "$(cfg keys.comment "$cf/inline.toml")" = c ]' "config: an inline table is not understood"
printf 'view = "off"\n[other]\nview = "rail"\n' >"$cf/table.toml"
check '[ "$(cfg view "$cf/table.toml")" = off ]' "config: keys under a table are ignored"
check '[ "$(cfgall /dev/null)" = "$defaults" ]' "config: no file means defaults"

hk="$work/hk"
mkdir -p "$hk/bin" "$hk/conf"
srv="$(printf '%s' /tmp/sockA | sha256sum | cut -c1-12)"
seed() {
  local d="$1"
  mkdir -p "$d"
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
}
cat >"$hk/bin/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "pane get p_live" | "pane get p1") echo '{"result":{"pane":{"pane_id":"'"$3"'","tab_id":"t1","workspace_id":"w1"}}}' ;;
  "pane get p_broken") echo '{"error":"protocol mismatch"}' >&2; exit 1 ;;
  "pane get p_stdout") echo '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  "pane get "*) echo '{"error":{"code":"pane_not_found"}}' >&2; exit 1 ;;
  "pane read "*) echo "$*" >>"$HK_LOG"; exit 1 ;;
  "notification show "*) echo "$3" >>"$HK_LOG" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$hk/bin/herdr"
export HK_LOG="$hk/log"
housekeep() {
  : >"$HK_LOG"
  HERDR_SOCKET_PATH=/tmp/sockA HERDR_BIN_PATH="$hk/bin/herdr" HERDR_PLUGIN_ID=x \
    HERDR_PLUGIN_CONTEXT_JSON='{"focused_pane_id":"p1"}' TMPDIR="$hk" "$plugin/open.sh" >/dev/null 2>&1
}
listing() { (cd "$1" && ls | sort | tr '\n' ' '); }
want="$(printf '%s\n' "$srv-p_broken.json" "$srv-p_live.json" "$srv-p_stdout.json" b.json.tmp.2 other-p_dead.json young.json | sort | tr '\n' ' ')"
seed "$hk/plugin-state"
seed "$hk/xdg/vimnotate"
printf 'lines = 250\n' >"$hk/conf/config.toml"
HERDR_PLUGIN_STATE_DIR="$hk/plugin-state" HERDR_PLUGIN_CONFIG_DIR="$hk/conf" XDG_STATE_HOME="$hk/xdg" housekeep
left="$(listing "$hk/plugin-state")"
check '[ "$left" = "$want" ]' "open.sh housekeeping in HERDR_PLUGIN_STATE_DIR keeps exactly: $want (got: $left)"
check '[ "$(ls "$hk/xdg/vimnotate" | wc -l)" -eq 9 ]' "open.sh leaves the XDG state dir alone when HERDR_PLUGIN_STATE_DIR is set"
check 'grep -q -- "--source recent-unwrapped --format ansi --lines 250" "$HK_LOG"' "open.sh captures config.toml's lines"
XDG_STATE_HOME="$hk/xdg" housekeep
left="$(listing "$hk/xdg/vimnotate")"
check '[ "$left" = "$want" ]' "open.sh housekeeping falls back to XDG_STATE_HOME/vimnotate (got: $left)"
check 'grep -q -- "--source recent-unwrapped --format ansi --lines 1000" "$HK_LOG"' "open.sh captures 1000 lines with no config"
check '[ -z "$(find "$hk" -maxdepth 1 -name "herdr-vimnotate.*")" ]' "open.sh removes its temp dir when the pane read fails"

pp="$work/pp"
mkdir -p "$pp/bin" "$pp/conf" "$pp/noconf"
for c in bash dirname sha256sum cut tr seq jq sleep stty cat grep awk rm env sort; do
  ln -s "$(command -v "$c")" "$pp/bin/$c"
done
ln -s "$hk/bin/herdr" "$pp/bin/herdr"
cat >"$pp/bin/nvim" <<'EOF'
#!/usr/bin/env bash
env | grep -E '^VIMNOTATE_(VIEW|ACTION_BAR|RESTORE|STATE|KEY_[A-Z_]+)=' | sort >"$HK_LOG.env"
printf 'line one\nline two\n' >"$VIMNOTATE_REPLY"
[ -z "${HK_EDIT:-}" ] || printf 'force_send = false\n' >"$HK_EDIT"
EOF
chmod +x "$pp/bin/nvim"
cat >"$pp/conf/config.toml" <<'EOF'
view = "rail"
action_bar = "never"
restore = false
force_send = true

[keys]
looks_good = "a"
EOF
pane_run() {
  : >"$HK_LOG"
  rm -rf "$pp/run"
  mkdir -p "$pp/run"
  : >"$pp/run/visible.ansi"
  PATH="$pp/bin" HERDR_BIN_PATH=herdr HERDR_SOCKET_PATH=/tmp/sockA VIMNOTATE_DIR="$pp/run" VIMNOTATE_TARGET_PANE=p1 VIMNOTATE_TAB=t0 \
    "$plugin/herdr-vimnotate.sh" >/dev/null 2>&1
}
HERDR_PLUGIN_CONFIG_DIR="$pp/conf" HERDR_PLUGIN_STATE_DIR="$pp/state" XDG_STATE_HOME="$pp/xdg" pane_run
got="$(tr '\n' ' ' <"$HK_LOG.env")"
check '[ "$got" = "VIMNOTATE_ACTION_BAR=never VIMNOTATE_KEY_COMMENT=c VIMNOTATE_KEY_DELETE=d VIMNOTATE_KEY_LOOKS_GOOD=a VIMNOTATE_RESTORE=false VIMNOTATE_STATE=$pp/state/$srv-p1.json VIMNOTATE_VIEW=rail " ]' "herdr-vimnotate.sh passes config.toml and HERDR_PLUGIN_STATE_DIR to nvim (got: $got)"
check 'grep -q "^Annotation send failed" "$HK_LOG"' "force_send sends a multi-line review to a pane with no agent"
mkdir -p "$pp/edit"
cp "$pp/conf/config.toml" "$pp/edit/config.toml"
HK_EDIT="$pp/edit/config.toml" HERDR_PLUGIN_CONFIG_DIR="$pp/edit" XDG_STATE_HOME="$pp/xdg" pane_run
check 'grep -q "^Annotation send failed" "$HK_LOG"' "config.toml edited during a review doesn't change it"
HERDR_PLUGIN_CONFIG_DIR="$pp/noconf" XDG_STATE_HOME="$pp/xdg" pane_run
got="$(tr '\n' ' ' <"$HK_LOG.env")"
check '[ "$got" = "VIMNOTATE_ACTION_BAR=always VIMNOTATE_KEY_COMMENT=c VIMNOTATE_KEY_DELETE=d VIMNOTATE_KEY_LOOKS_GOOD=p VIMNOTATE_RESTORE=true VIMNOTATE_STATE=$pp/xdg/vimnotate/$srv-p1.json VIMNOTATE_VIEW=inline " ]' "herdr-vimnotate.sh defaults with no config.toml, state under XDG_STATE_HOME (got: $got)"
check 'grep -q "^Annotations not sent" "$HK_LOG"' "a multi-line review to a pane with no agent is not sent by default"

lk="$work/lk"
mkdir -p "$lk/bin"
for c in bash dirname sha256sum cut tr seq jq sleep stty cat grep awk rm env sort mktemp find; do
  ln -s "$(command -v "$c")" "$lk/bin/$c"
done
cp "$pp/bin/nvim" "$lk/bin/nvim"
printf '%s\n' '[ -z "${LK_RENAME:-}" ] || echo "$LK_RENAME" >"$LK_DIR/label"' >>"$lk/bin/nvim"
cat >"$lk/bin/herdr" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$LK_LOG"
case "$*" in
  "pane get p1") printf '{"result":{"pane":{"pane_id":"p1","tab_id":"%s","workspace_id":"w1"}}}\n' "$(cat "$LK_DIR/tab")" ;;
  "pane layout --pane "*) printf '{"result":{"layout":{"zoomed":%s}}}\n' "$(cat "$LK_DIR/zoomed")" ;;
  "pane zoom "*" --on") echo true >"$LK_DIR/zoomed" ;;
  "pane zoom "*" --off") echo false >"$LK_DIR/zoomed" ;;
  "pane read "*) echo text ;;
  "plugin pane open "*) echo '{"result":{"plugin_pane":{"pane":{"pane_id":"pv"}}}}' ;;
  "pane move p1 --new-tab "*) echo tp >"$LK_DIR/tab" ;;
  "pane move p1 --tab "*) echo t1 >"$LK_DIR/tab" ;;
  "tab get t1") jq -nc --arg l "$(cat "$LK_DIR/label")" '{result:{tab:{tab_id:"t1",label:$l,number:3}}}' ;;
  "tab list --workspace w1") jq -nc --arg l "$(cat "$LK_DIR/label")" '{result:{tabs:[{tab_id:"t0",label:"1",number:1},{tab_id:"t1",label:$l,number:3}]}}' ;;
  "tab rename t1 "*) shift 3; echo "$*" >"$LK_DIR/label" ;;
esac
EOF
chmod +x "$lk/bin/herdr"
export LK_LOG="$lk/log" LK_DIR="$lk"
lk_open() {
  : >"$LK_LOG"
  echo t1 >"$lk/tab"
  echo "$1" >"$lk/zoomed"
  printf '%s\n' "${2-2}" >"$lk/label"
  PATH="$lk/bin" HERDR_BIN_PATH=herdr HERDR_SOCKET_PATH=/tmp/sockA HERDR_PLUGIN_ID=x XDG_STATE_HOME="$lk/xdg" \
    HERDR_PLUGIN_CONTEXT_JSON='{"focused_pane_id":"p1"}' TMPDIR="$lk" "$plugin/open.sh" >/dev/null 2>&1
}
lk_pane() {
  : >"$LK_LOG"
  echo tp >"$lk/tab"
  echo false >"$lk/zoomed"
  printf '%s\n' "${2-2}" >"$lk/label"
  rm -rf "${lk:?}/run"
  mkdir -p "$lk/run"
  : >"$lk/run/visible.ansi"
  PATH="$lk/bin" HERDR_BIN_PATH=herdr HERDR_SOCKET_PATH=/tmp/sockA HERDR_PANE_ID=pv XDG_STATE_HOME="$lk/xdg" \
    VIMNOTATE_DIR="$lk/run" VIMNOTATE_TARGET_PANE=p1 VIMNOTATE_TAB=t1 VIMNOTATE_ZOOMED="$1" VIMNOTATE_TAB_LABEL="${3-}" VIMNOTATE_TAB_RENAME="${4:-false}" \
    "$plugin/herdr-vimnotate.sh" >/dev/null 2>&1
}
calls() { grep -E '^pane (zoom|move)' "$LK_LOG" | tr '\n' ';'; }
lk_open true
got="$(calls)"
check '[ "$got" = "pane zoom p1 --off;pane move pv --tab t1 --target-pane p1 --split down --focus;pane move p1 --new-tab --workspace w1 --no-focus --label 2 [parked by vimnotate];" ]' "open.sh unzooms a zoomed target before taking its slot (got: $got)"
check 'grep -q "VIMNOTATE_ZOOMED=true" "$LK_LOG"' "open.sh tells the pane the target was zoomed"
lk_open false
got="$(calls)"
check '[ "$got" = "pane move pv --tab t1 --target-pane p1 --split down --focus;pane move p1 --new-tab --workspace w1 --no-focus --label 2 [parked by vimnotate];" ]' "open.sh leaves an unzoomed target's zoom alone (got: $got)"
lk_pane true
got="$(calls)"
check '[ "$got" = "pane zoom pv --on;pane zoom pv --off;pane move p1 --tab t1 --target-pane pv --split down --focus;pane move pv --new-tab --no-focus;pane zoom p1 --on;" ]' "a zoomed review hands the zoom back to the target (got: $got)"
lk_pane false
got="$(calls)"
check '[ "$got" = "pane move p1 --tab t1 --target-pane pv --split down --focus;" ]' "an unzoomed review returns the target without zooming (got: $got)"
check '! grep -q "^tab rename" "$LK_LOG"' "an auto-named tab is never renamed"
lk_open false build
check 'grep -q -- "--label build \\[parked by vimnotate\\]" "$LK_LOG" && grep -q "VIMNOTATE_TAB_RENAME=true --env VIMNOTATE_TAB_LABEL=build\$" "$LK_LOG"' "open.sh names the parked tab after a labelled tab"
lk_open false
check 'grep -q "VIMNOTATE_TAB_RENAME=false" "$LK_LOG"' "open.sh treats a tab labelled with its position as auto-named"
lk_open false 3
check 'grep -q "VIMNOTATE_TAB_RENAME=true" "$LK_LOG"' "open.sh compares the label with the tab's position, not its stable number"
lk_open false ""
check 'grep -q -- "--label \\[parked by vimnotate\\]" "$LK_LOG" && grep -q "VIMNOTATE_TAB_RENAME=true --env VIMNOTATE_TAB_LABEL=\$" "$LK_LOG"' "open.sh keeps an explicitly empty label"
lk_pane false build build true
got="$(grep "^tab rename" "$LK_LOG" | tr '\n' ';')"
check '[ "$got" = "tab rename t1 vimnotate: build;tab rename t1 build;" ] && [ "$(cat "$lk/label")" = build ]' "a labelled tab is renamed while annotating and restored after (got: $got)"
lk_pane false "" "" true
got="$(grep "^tab rename" "$LK_LOG" | tr '\n' ';')"
check '[ "$got" = "tab rename t1 vimnotate;tab rename t1 ;" ]' "an empty label becomes vimnotate and comes back empty (got: $got)"
lk_pane false other build true
check '! grep -q "^tab rename" "$LK_LOG" && [ "$(cat "$lk/label")" = other ]' "a tab renamed before the review starts is left alone"
LK_RENAME=mine lk_pane false build build true
check '[ "$(cat "$lk/label")" = mine ]' "a tab the user renamed mid-review keeps the user's name"

empty() { awk -f "$plugin/composer-empty.awk"; }
r="\033[90m────────\033[0m"
check 'printf "some output\n$r\n❯ \n$r\n  \033[90m? for shortcuts\033[0m\n" | empty' "composer-empty: lone prompt between rules"
check 'printf "$r\n❯\n$r\n" | empty' "composer-empty: prompt without trailing space"
check '! printf "$r\n❯ half typed\n$r\n" | empty' "composer-empty: typed text"
check '! printf "$r\n❯ line one\n  line two\n$r\n" | empty' "composer-empty: multi-line draft"
check '! printf "plain shell\n$ \n" | empty' "composer-empty: no composer"
check '! printf "$r\n❯ \n$r\nmore\n$r\nx\n$r\n" | empty' "composer-empty: last rule pair decides"
for a in claude codex pi; do
  check 'empty <"$fx/composer-$a-empty.ansi"' "composer-empty: $a, empty"
  for st in typed multi; do
    check '! empty <"$fx/composer-$a-$st.ansi"' "composer-empty: $a, $st draft"
  done
done
check '! empty <"$fx/composer-codex-blankfirst.ansi"' "composer-empty: codex draft below a blank first line"
check '! empty <"$fx/composer-pi-rule.ansi"' "composer-empty: pi draft holding a typed rule"
check '! empty <"$fx/composer-pi-gt.ansi"' "composer-empty: pi draft that is a lone >"
check '! empty <"$fx/composer-pi-below.ansi"' "composer-empty: empty ruled box with a draft below it"
check '! empty <"$fx/composer-codex-chevron.ansi"' "composer-empty: codex continuation line starting with ›"
check '! empty <"$fx/composer-codex-chevron0.ansi"' "composer-empty: codex continuation › at column 0"
check '! printf "────────\n❯ \n────────\n" | empty' "composer-empty: rules in the default colour are typed text"
check '! printf "$r\n❯ \n\n$r\n" | empty' "composer-empty: a box of more than one line"
check 'printf "$r\n❯ \033[2mTry something\033[0m\n$r\n" | empty' "composer-empty: faint placeholder"
check 'printf "$r\n❯ \033[0;2mTry\033[22m\033[2m more\033[m\n$r\n" | empty' "composer-empty: combined faint params"
check '! printf "$r\n❯ \033[2mTry\033[22m typed\n$r\n" | empty' "composer-empty: 22 ends faint"
check '! printf "$r\n❯ \033[1;38;2;2;2;2mtyped\033[0m\n$r\n" | empty' "composer-empty: truecolor 2s are not faint"
check 'printf "$r\n❯ \033[1;2;38;2;9;9;9mhint\033[0m\n$r\n" | empty' "composer-empty: faint among colour params"
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
