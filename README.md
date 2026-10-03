# herdr-vimnotate

`prefix+a` opens the focused pane's thread in neovim, in that pane's own layout slot, so you can review an agent's reply with vim operators: `cap` comments on a paragraph, `dap` marks one for deletion, `pp` says a line looks good, `.` repeats the last one. `q` sends the whole review back as one message, sitting unsubmitted in the agent's composer. It is meant to feel like a built-in mode, the way herdr's copy mode does, not like a popup that landed on top of your work.

The point is the seam you don't see. Press the key and the pane appears to stay exactly where it was, same size, same content, same position in the layout, except now it takes vim motions. Quit and your pane is back with the review in the composer.

[![vimnotate reviewing a Claude Code reply: p marks paragraphs as looking good, d deletes one, c comments on another, q sends the review to the agent's composer](docs/vimnotate-demo.webp)](docs/vimnotate-demo.mp4)

Click the image to watch the [25-second demo](docs/vimnotate-demo.mp4).

> **Renamed from `herdr-annotate-thread`.** The plugin id changed from `aksh1618.annotate-thread` to `aksh1618.vimnotate`, so herdr treats it as a different plugin. If you installed the old one, run `herdr plugin uninstall aksh1618.annotate-thread`, install `aksh1618/herdr-vimnotate`, and point your `prefix+a` binding at `aksh1618.vimnotate.open`. The environment knobs were renamed with it: `ANNOTATE_LINES` is now `VIMNOTATE_LINES` and `ANNOTATE_FORCE_SEND` is now `VIMNOTATE_FORCE_SEND`.

It is **0.x**: in daily use, but young, and so far only run against my own neovim config.

## Install

```sh
herdr plugin install aksh1618/herdr-vimnotate
```

Then bind it, in herdr's `config.toml`:

```toml
[[keys.command]]
key = "prefix+a"
type = "plugin_action"
command = "aksh1618.vimnotate.open"
description = "Vimnotate: annotate thread in nvim"
```

To hack on it, clone the repo and `herdr plugin link <path>` instead.

## Flow

1. Optionally select something in herdr's copy mode first. The selection reaches the action as `selected_text`; vimnotate finds it in the thread and opens the comment popup on it. If it can't be found, it's quoted into the general note instead.
2. `prefix+a`. The thread opens in place, scrolled to the bottom, in a read-only buffer.
3. Annotate with the operators below. Each annotation is a coloured highlight over its range plus a box under it with your comment (or, with `R`, a bubble in a side rail).
4. `q` (or `:qa`, or `:Send`) sends. The target pane comes back and the review is pasted into its composer **unsubmitted**, so you read it back and press Enter yourself. `:Cancel` throws the review away.

## Keys

In the thread:

| Key | What it does |
| --- | --- |
| `c{motion}`, `cc`, `C`, visual `c` | Comment. Opens a compose popup below the range. |
| `d{motion}`, `dd`, visual `d` | Mark for deletion ("Remove this."), with an optional reason. |
| `p{motion}`, `pp`, visual `p` | Mark as looking good ("Looks good."). |
| `.` | Repeat the last operator on a new range. Counts work too (`3cc`). |
| `e` / `x` / `K` | Edit / remove / show the annotation under the cursor. |
| `]a` / `[a` | Next / previous annotation. If nvim-treesitter-textobjects is installed they register with its `repeatable_move`, so its `;` and `,` repeat them. |
| `u` / `<C-r>` | Undo / redo annotation changes (add, remove, edit, kind change), one step per keypress. |
| `<C-o>` / `<C-i>` | The jumplist, confined to the thread: it starts empty and can't walk into other files. |
| `R` | Cycle the view: inline boxes → side rail → off. |
| `<S-Tab>` | Focus the side rail. |
| `<Tab>` | Open the general note, a popup whose text is sent above the annotations. |
| `q` | Send and quit. |

Operators add a new annotation, even over an existing one; `e` is how you edit. The exception is a restored [sent](#restoring-sent-annotations) annotation: `d`, `p` or `c` on exactly its range changes its kind and makes it pending again (`c` opens the compose popup on it). Motions and text objects are vim's own, so `w`, `ap`, `}` and whatever text objects your config adds all work.

The compose popup is an ordinary vim buffer: `Enter` saves (in insert or normal mode), `Ctrl-j` inserts a new line, `Esc` goes to normal mode and `q` there cancels.

The note popup is a plain buffer too, but `Enter` is just a newline. `q` or `Tab` in normal mode hides it, and so does clicking back into the thread. Hiding never discards the note; only `:Cancel` does.

In the side rail: `j`/`k` move between annotations, `Enter` jumps to one in the thread, `e` edits, `x` removes, `Esc` or `Tab` goes back to the thread.

With the mouse: dragging a selection shows an action bar with clickable "looks good", "comment" and "delete" labels. Resting the cursor on an annotation shows a hint bar for `e`, `x` and `K`.

## What gets sent

The general note first, then each annotation as a quote of the text it covers followed by the reply, separated by blank lines:

```
Overall fine, but keep it shorter.

> For versioning I'd use SemVer.

Looks good.

> Tag the commit with an annotated tag.

Use a signed tag and push only that one

> Add a GitHub Action later.

Remove this.
```

A comment line starting with `>` is sent as `\>`, so it never reads as quoted text.

When the pane is running Claude Code and its composer is empty, the review is pasted as-is. Otherwise it's separated from whatever is already in the composer, by a blank line for a multi-line review or a space for a one-liner, so a second review never glues onto unsent text.

## Restoring sent annotations

When you send, the annotations are saved for that pane. Open the same pane again and they're found again in the new capture and shown dimmed, marked as sent. They're left out of the next send unless you edit or re-mark one, which makes it pending again; `x` removes one for good.

Each one is matched by its text plus up to five non-blank lines of context on each side, so new output above it or repeated lines don't move it to the wrong place. One that can't be found is carried forward, not dropped. The state lives in `$XDG_STATE_HOME/vimnotate/` (`~/.local/state/vimnotate/`), one file per herdr server and pane, `0600` in a `0700` directory. Each time vimnotate opens, it deletes files older than 7 days and files whose pane herdr reports as gone.

## Settings

Set these in your neovim config; the session loads it.

| Setting | Values |
| --- | --- |
| `vim.g.vimnotate_view` | `"inline"` (default) boxes under each range; `"rail"` a side rail; `"auto"` the rail when the thread still keeps 80 columns, else inline; `"off"` highlights only. `R` switches at runtime. |
| `vim.g.vimnotate_action_bar` | `"mouse"` (default) shows the action bar only for mouse selections; `"always"` for every visual selection; `"never"`. |
| `vim.g.vimnotate_restore` | `true` (default); `false` doesn't show sent annotations again, but still keeps them saved. |

And two environment variables, read from herdr's environment:

- `VIMNOTATE_LINES`: how much scrollback to capture. Defaults to 1000, which is also the most `pane read --lines` returns.
- `VIMNOTATE_FORCE_SEND=1`: send a multi-line review to a pane with no agent anyway (see [Sending](#sending)).

## How it takes the pane's slot

herdr has no pane-local placement. `popup` is centred over everything, `overlay` is a zoomed split, and a plugin pane can only be placed in a tab. So the slot is taken rather than asked for, in `open.sh`:

1. **Capture first, split second.** `pane read --source visible` and `--source recent-unwrapped --format ansi` both run *before* anything moves, because a split resizes the target pane and rewraps its scrollback. Capture afterwards and you have recorded the wrong layout.
2. Open the plugin pane in a temporary tab, unfocused.
3. `pane move` it into the target's tab, split below the target, focused.
4. `pane move` the *target* out into its own tab, labelled `vimnotate · parked`.

The vimnotate pane is now the only pane in that slot, at the target's dimensions. On exit the target is moved back in beside it and the vimnotate pane closes, leaving the target in its old slot. Pane ids, processes, scrollback and labels all survive; nothing is recreated.

Then the part that makes it invisible: the pane enters the alternate screen, prints the captured `visible.ansi` and only then starts nvim over it, so there is no flash of an empty shell between the two.

### The resize that isn't

**`pane move` never resizes the pane it moves.** Geometry is not on the list of things a move re-applies, so the pane arrives carrying its old dimensions and renders at the wrong width. The fix is a no-op resize (`pane resize --direction right --amount 0`) on each pane that lands in the slot, the vimnotate pane when it arrives and the target when it returns, which forces herdr to re-apply the real geometry.

It has to be issued from *inside* the alternate screen. A pane on the primary screen keeps a column reserved for its scrollbar, so a resize there settles one column narrower than the slot, and the copy stops being pixel-perfect by exactly one column. The script waits for `stty size` to actually change (retrying the resize once, and giving up after about half a second) rather than sleeping a fixed interval.

Both of these work around herdr 0.9 behaviour. If a later herdr re-applies geometry on `pane move`, the resize becomes a harmless no-op.

## Rendering

The thread is a **normal, non-modifiable buffer**, not a terminal buffer, with the pane's ANSI parsed into extmark highlights by hand. A terminal buffer looked like the obvious host and is the wrong one: it pre-maps the mouse and cancels visual mode on `nvim_set_current_win`, which kills the selection gesture this plugin is built around.

Annotations are extmarks on that buffer, so they move with the text: the highlights are `hl_group` ranges, the inline boxes are `virt_lines`, and the compose popup opens over blank virtual lines reserved where the box will land, so it never covers the thread and saving it doesn't make anything jump.

## Sending

The review goes back through `pane.send_input` over the socket, which pastes it as one bracketed chunk. Raw `send-text` is not usable: its newlines each submit, so a multi-line review would fire as several messages.

If the target pane has **no agent** and the review is multi-line, it is copied to the clipboard and a notification says so, instead of being typed into a shell a line at a time. `VIMNOTATE_FORCE_SEND=1` overrides that. If the send fails, the review is copied to the clipboard too. With no clipboard tool, the review file is kept instead and the notification gives its path.

## Privacy

nvim runs with `-i NONE` and `undofile` off, so a review never reads or writes your ShaDa (search and command history, registers) or leaves its text in your undo directory. Swap files are off too. The capture lives in a `mktemp -d` directory that is removed on exit. The only thing kept is the restore state above.

## Requirements

- herdr **0.9.0+** (`min_herdr_version`; the placement needs `pane move`'s `--target-pane` and `--new-tab`)
- neovim **0.11+**. Developed on 0.12; the test suite passes on 0.11.0 and fails on 0.10, which lacks the floating-window `mouse` option and key-discarding `vim.on_key`.
- `bash`, `jq`, `socat`, `awk`, and `sha256sum` or `shasum`
- `wl-copy`, `xclip`, `xsel` or `pbcopy` for the clipboard fallback (optional)

The manifest lists macOS and the scripts avoid GNU-only tools, but it has only been run on Linux.

## Tuned to me

This is the least portable part, and knowingly so. It runs your full neovim config, then bends it:

- It deletes global maps that would make its keys ambiguous, for the length of the session. A global `cs` (surround plugins) or `]ab` makes `c` or `]a` wait out `timeoutlen` before deciding, and a buffer-local exact match does *not* escape that wait. It re-checks after every lazy.nvim `LazyLoad`, since a lazy-loaded plugin can map them later.
- It deletes global left-mouse maps and forces `mouse=a`. My own config disables the mouse; the drag-select gesture needs it.
- It hides `lualine` if you have it, and keeps `laststatus=0`.
- The compose and note popups are `filetype=markdown`, which pulls in whatever markdown stack you load. It's pre-warmed on a throwaway buffer so it doesn't load inside the first keypress.
- The empty-composer check recognises Claude Code's prompt (a lone `❯` between two rules). Other agents always get the separator.

## Layout

- `open.sh`: the action. Expires old restore state, captures, opens the plugin pane, performs the two moves.
- `herdr-vimnotate.sh`: the pane entrypoint. Alternate screen, geometry re-apply, runs nvim, restores the layout, sends or falls back to the clipboard.
- `vimnotate.lua`: the nvim session: ANSI rendering, annotations, operators, popups, rail, undo, restore, export.
- `composer-empty.awk`: the empty-composer check.
- `tests/`: the test suite.

## Running the tests

```sh
tests/run.sh
```

It drives headless `nvim --clean` against fixture captures and a stub `herdr`, so it never touches a running herdr or your neovim config. It takes a few seconds and exits non-zero on any failure. It needs `nvim`, `jq` and GNU coreutils.

## License

[Apache-2.0](LICENSE), the same as herdr.
