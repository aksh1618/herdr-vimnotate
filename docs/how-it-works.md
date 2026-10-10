# How vimnotate works

Internals, for anyone changing the code or curious why it behaves the way it does. The user-facing side is in the [README](../README.md).

## How it takes the pane's slot

herdr has no pane-local placement. `popup` is centred over everything, `overlay` is a zoomed split, and a plugin pane can only be placed in a tab. So the slot is taken rather than asked for, in `open.sh`:

1. **Capture first, split second.** `pane read --source visible` and `--source recent-unwrapped --format ansi` both run *before* anything moves, because a split resizes the target pane and rewraps its scrollback. Capture afterwards and you have recorded the wrong layout.
2. Open the plugin pane in a temporary tab, unfocused.
3. `pane move` it into the target's tab, split below the target, focused.
4. `pane move` the *target* out into its own tab, labelled `<tab> [parked by vimnotate]`, and rename the target's tab `vimnotate: <tab>`.

**Tab names.** herdr's `tab rename` always sets a fixed label, and nothing clears one, so a tab herdr names by its position can't be handed back to automatic naming. A tab whose label equals its position in `tab list` is treated as automatic and isn't renamed, since restoring the position would freeze it and go stale once tabs move or close. (`tab get`'s `number` is a stable id, not the position.) A labelled tab is renamed only if its label is still the one captured at open, and gets it back on exit unless the user renamed it during the review. A tab with an empty label becomes `vimnotate`, and its parked tab `[parked by vimnotate]`.

The vimnotate pane is now the only pane in that slot, at the target's dimensions. On exit the target is moved back in beside it and the vimnotate pane closes, leaving the target in its old slot. Pane ids, processes, scrollback and labels all survive; nothing is recreated.

**Zoom.** herdr refuses to move a pane into or out of a zoomed tab: the move exits 0 but reports `changed: false` with reason `zoomed_tab`. So a zoomed target is unzoomed after the capture and before the moves, and the vimnotate pane zooms itself once it is in the slot. On exit both tabs are unzoomed so the target can move back, and if the vimnotate pane was still zoomed, the zoom is handed to the target. Closing a pane always clears its tab's zoom, so the vimnotate pane first moves out to a tab of its own, and the target is zoomed only once that move has actually happened.

Then the part that makes it invisible: the pane enters the alternate screen, prints the captured `visible.ansi` and only then starts nvim over it, so there is no flash of an empty shell between the two.

### The resize that isn't

**`pane move` never resizes the pane it moves.** Geometry is not on the list of things a move re-applies, so the pane arrives carrying its old dimensions and renders at the wrong width. The fix is a no-op resize (`pane resize --direction right --amount 0`) on each pane that lands in the slot, the vimnotate pane when it arrives and the target when it returns, which forces herdr to re-apply the real geometry.

It has to be issued from *inside* the alternate screen. A pane on the primary screen keeps a column reserved for its scrollbar, so a resize there settles one column narrower than the slot, and the copy stops being pixel-perfect by exactly one column. The script waits for `stty size` to actually change (retrying the resize once, and giving up after about half a second) rather than sleeping a fixed interval.

Both of these work around herdr 0.9 behaviour. If a later herdr re-applies geometry on `pane move`, the resize becomes a harmless no-op.

## Rendering

The thread is a **normal, non-modifiable buffer**, not a terminal buffer, with the pane's ANSI parsed into extmark highlights by hand. A terminal buffer looked like the obvious host and is the wrong one: it pre-maps the mouse and cancels visual mode on `nvim_set_current_win`, which kills the selection gesture this plugin is built around.

Annotations are extmarks on that buffer, so they move with the text: the highlights are `hl_group` ranges, the inline boxes are `virt_lines`, and the compose popup opens over blank virtual lines reserved where the box will land, so it never covers the thread and saving it doesn't make anything jump.

## Keys

An operator key is valid when it is one printable ASCII character other than a space, the three keys differ, and none is already a thread key (`x`, `e`, `K`, `u`, `q`, `R`, `H`, `L`, `g`, `v`, `V`, `.`, `:`, a digit, or `]`/`[`). If any isn't, all three fall back to `c`, `d` and `p`, and the winbar says why. `config.awk` passes any quoted key through and nvim does the check, since the list of thread keys lives in Lua.

`a` and `i` work as operator keys, but they also start text objects (`ap`, `iw`, and any a config adds, such as `af`), so they stay text objects after another operator and in visual mode:

- Taking `a` as the example, `a{motion}` works as usual, and the line form is `aaa` (`a` then `aa`, as `ap` is `a` then `ap`) or `a_`. Counts work: `3aaa`.
- `a` isn't mapped in visual mode, so use the action bar there: its label for that operator shows no key.
- Your own `a`/`i` text objects are never deleted as [ambiguous maps](../README.md#does-it-edit-my-neovim-config).

**The `q` guard.** For 400 ms after you come back to the thread from a popup or the rail (by key or by click), `q` doesn't send and the winbar shows `q sends` instead, so the `q` that closed a popup can't send on a double tap. `:Send` and `:qa` always send.

## Colours

The winbar starts with an amber `VIMNOTATE` badge and has a warm, muted tint. The bottom row gets the same tint only when `cmdheight` is above 0; with `cmdheight=0` there is no bottom row. The thread window's `winhighlight` maps `WinBar` to `VimnotateWinbar`, and `MsgArea` links to `VimnotateMsgArea`. The colours are picked for `background=dark` or `light`, and re-picked when it changes:

| Group | What it colours | Dark | Light | cterm |
| --- | --- | --- | --- | --- |
| `VimnotateMode` | The badge, bold. | `#1c1c1c` on `#ffc340` | the same | 214 |
| `VimnotateWinbar` | The rest of the top row, over the thread and the side rail. | `#d6cbb0` on `#2b2620` | `#4a3c1e` on `#f2e6c9` | 251 on 235, 237 on 223 |
| `VimnotateMsgArea` | The bottom row, when `cmdheight` is above 0. | links to `VimnotateWinbar` | | |

A group that something else has already set is left alone, so your own definition wins; if your colorscheme loads after vimnotate, set it in a `ColorScheme` autocmd. To leave the bottom row untinted, link `VimnotateMsgArea` to `Normal`: an empty `{}` group counts as unset and is filled in again. A keymap warning on the winbar uses the colorscheme's `WarningMsg`.

## The clipboard anchor

A mouse selection never reaches a plugin action: the prefix key clears it before the action runs, so only a copy-mode selection arrives as `selected_text`. But with its default `ui.copy_on_select = true` herdr copies every mouse selection to CLIPBOARD (never PRIMARY), so when there is no `selected_text`, `open.sh` reads CLIPBOARD as text (`wl-paste --type text`, `xclip -selection clipboard`, `xsel --clipboard` or `pbpaste`). The tool runs in the background and is killed after half a second or once it has written more than 64 KiB, so a stuck clipboard owner can't stall `prefix+a`. Its output counts only if it exited successfully within both limits; anything partial is discarded rather than used, since a truncated prefix could match the wrong text.

The text goes to `clipboard.txt` in the review's `0700` temp dir, created `0600`. nvim reads and deletes it at startup and uses it only if it has at least 8 non-blank characters and is found in the thread; otherwise it is dropped silently. When it anchors, its SHA-256 is written to `<server>.clip` in the state dir, and `open.sh` skips clipboard text with that hash, so a stale clipboard doesn't reopen the popup on every later review. Only that hash of text already shown in the thread is kept; the clipboard text itself never leaves the temp dir.

## Sending

The review goes back through `pane.send_input` over the socket, which pastes it as one bracketed chunk. Raw `send-text` is not usable: its newlines each submit, so a multi-line review would fire as several messages.

If the target pane has **no agent** and the review is multi-line, it is copied to the clipboard and a notification says so, instead of being typed into a shell a line at a time. `force_send = true` in the [config](../README.md#configuration) overrides that. If the send fails, the review is copied to the clipboard too. With no clipboard tool, the review's temp directory is kept instead, captures included, and the notification gives the review file's path.

## Restoring sent annotations

Each sent annotation is matched by its text plus up to five non-blank lines of context on each side, so new output above it or repeated lines don't move it to the wrong place. One that can't be found is carried forward, not dropped. The state lives in vimnotate's herdr plugin state directory (`$HERDR_PLUGIN_STATE_DIR`, usually `~/.local/state/herdr/plugins/aksh1618.vimnotate/`; `$XDG_STATE_HOME/vimnotate/` or `~/.local/state/vimnotate/` when run outside herdr), one file per herdr server and pane, `0600` in a `0700` directory. Each time vimnotate opens, it deletes files older than 7 days and files whose pane herdr reports as gone.

## Minimum versions

- **herdr 0.9.0** (`min_herdr_version` in the manifest): the slot takeover (`plugin pane open --placement tab`, then two `pane move`s) and the copy-mode `selected_text` hand-off were built and tested on 0.9.0. It is untested on earlier versions, and the workarounds in [The resize that isn't](#the-resize-that-isnt) are for 0.9's behaviour.
- **neovim 0.11**: developed on 0.12; the test suite passes on 0.11.0 and fails on 0.10, which lacks the floating-window `mouse` option and key-discarding `vim.on_key`.

## Running the tests

```sh
tests/run.sh
```

It drives headless `nvim --clean` against fixture captures and a stub `herdr`, so it never touches a running herdr or your neovim config. It takes a few seconds and exits non-zero on any failure. It needs `nvim`, `jq` and GNU coreutils.
