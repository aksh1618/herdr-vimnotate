# herdr-vimnotate

[![vimnotate reviewing a Claude Code reply: p marks paragraphs as looking good, d deletes one, c comments on another, q sends the review to the agent's composer](docs/vimnotate-demo.webp)](https://github.com/user-attachments/assets/3ee1c8e2-1a5e-4e24-8de4-9386772cc213)

(Click the image to watch the [25-second demo](https://github.com/user-attachments/assets/3ee1c8e2-1a5e-4e24-8de4-9386772cc213).)

Press `prefix+a` to switch to annotation mode for the focused Herdr pane, using neovim under the hood. You can review and annotate an agent's reply with vim motions for three operations:
1. `c` is comment
2. `d` is delete (remove this)
3. `p` is plus (looks good)

So, for example, `cap` comments on a paragraph, `dap` marks one for deletion, `pp` says a line looks good, `.` repeats the last one.

Once you're done, press `q` to send the whole review back as one message, sitting unsubmitted in the agent's composer.

While this plugin ~~copies~~ takes inspiration from the plannotator herdr annotation plugin for some of the UI/UX, it is meant to feel more like a built-in mode similar to herdr's copy mode (`prefix+[`) instead of a different TUI. All while giving you those sweet sweet vim motions, of course.

Currently **0.x**: I use it daily with my own herdr & neovim config, would love to hear feedback and any issues you run into if you try it, who knows maybe we'll even do 1.0 some day!

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

## Requirements

- herdr **0.9.0+** (what it's built and tested on)
- neovim **0.11+** (for floating-window mouse support; developed on 0.12)
- `bash`, `jq`, `socat`, `awk`, and `sha256sum` or `shasum`
- `wl-copy`, `xclip`, `xsel` or `pbcopy` for the clipboard fallback (optional)

The manifest lists macOS and the scripts avoid GNU-only tools, but it has only been run on Linux. Why these minimums: [docs/how-it-works.md](docs/how-it-works.md#minimum-versions).

## Flow

1. `prefix+a`. The thread opens in place, scrolled to the bottom, in a read-only buffer.
2. Navigate like neovim; Annotate with the c/d/p operators (more operators below). Or just use your mouse.
3. Each annotation is a coloured highlight over its range plus a box under it with your comment (or, with `R`, a bubble in a side rail).
4. `q` (or `:qa`, or `:Send`) once you're done.
5. The target pane comes back and the review is pasted into its composer **unsubmitted**, so you read it back and press Enter yourself.
6. `:Cancel` throws the review away.

Already selected something in herdr's copy mode? Press `prefix+a` with the selection still active and vimnotate opens with the comment popup on that text. If it can't find the text in the thread, it quotes it into the general note instead.

## Keymap

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

- Operators add a new annotation, even over an existing one; `e` is how you edit.
- The exception is a [restored annotation](#what-gets-sent) : `d`, `p` or `c` on exactly its range changes its kind and makes it pending again.
- Motions and text objects are vim's own, so `w`, `ap`, `}` and whatever text objects your config adds all work.
- The comment compose popup is an ordinary vim buffer: `Enter` saves (in insert or normal mode), `Ctrl-j` inserts a new line, `Esc` goes to normal mode and `q` there cancels.
- The note popup is a plain buffer too, but `Enter` is just a newline. `q` or `Tab` in normal mode hides it, and so does clicking back into the thread. Hiding never discards the note; only `:Cancel` does.
- In the side rail: `j`/`k` move between annotations, `Enter` jumps to one in the thread, `e` edits, `x` removes, `Esc` or `Tab` goes back to the thread.
- A visual selection (keyboard or mouse drag) shows an action bar with clickable "looks good", "comment" and "delete" labels. Resting the cursor on an annotation shows a hint bar for `e`, `x` and `K`.

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

When the agent's composer is empty, the review is pasted as-is; a dimmed placeholder such as Codex's `Ask Codex to do anything` counts as empty. Otherwise it's separated from whatever is already in the composer, by a blank line for a multi-line review or a space for a one-liner, so a second review never glues onto unsent text.

When you send, the annotations are saved for that pane. Open the same pane again and they're found again in the new capture and shown dimmed, marked as sent. They're left out of the next send unless you edit or re-mark one, which makes it pending again; `x` removes one for good. How they're matched and where the state lives: [docs/how-it-works.md](docs/how-it-works.md#restoring-sent-annotations).

## Configuration

Settings go in `config.toml` in vimnotate's herdr plugin config directory. To find it:

```sh
herdr plugin config-dir aksh1618.vimnotate
```

That's usually `~/.config/herdr/plugins/config/aksh1618.vimnotate/`. Every key is optional; this is the full set, at the defaults:

```toml
# "inline" boxes under each range, "rail" a side rail, "auto" the rail when the thread still keeps 80 columns (else inline), "off" highlights only. R switches at runtime.
view = "inline"

# "always" shows the action bar for every visual selection, "mouse" only for mouse selections, "never" not at all.
action_bar = "always"

# false doesn't show sent annotations again, but still keeps them saved.
restore = true

# How much scrollback to capture. 1000 is also the most `pane read --lines` returns.
lines = 1000

# true sends a multi-line review to a pane with no agent anyway (see docs/how-it-works.md#sending).
force_send = false
```

- It's read each time vimnotate opens, so changes apply to the next review without restarting herdr.
- Only flat `key = value` lines are understood: strings in double quotes, `true`/`false`, whole numbers and `#` comments.
- Unknown keys/values are ignored.

## FAQ

### How does it work?

How the pane's slot is taken and given back, how the thread is rendered, how the review is sent, how sent annotations are matched again, and how to run the tests: [docs/how-it-works.md](docs/how-it-works.md).

### Does it share anything with my everyday neovim?

vimnotate loads your neovim config, but a review session shares no state with your other neovim sessions, in either direction:

- nvim runs with `-i NONE` (no ShaDa), so a review never adds its searches, commands or yanked thread text to your history and registers, and your jumplist and old files never leak into the thread (`<C-o>` can't walk into them).
- `undofile` is off, so review text never lands in your undo directory. Swap files are off too.
- The capture lives in a `mktemp -d` directory that is removed on exit. The only thing kept is the [restore](#what-gets-sent) state.

### Does it edit my neovim config?

No. The plugin needs to override some neovim config to work well, but only inside the review's own nvim process: your config files aren't touched, and any other neovim you open, even mid-review, is unaffected. This is likely the least portable part, and the most susceptible to config-specific breakage. File an issue if you run into anything!

- Global maps that would make its keys ambiguous are deleted for the length of the session. A global `cs` (surround plugins) or `]ab` makes `c` or `]a` wait out `timeoutlen` before deciding, and a buffer-local exact match does *not* escape that wait. They're re-checked after every lazy.nvim `LazyLoad`, since a lazy-loaded plugin can map them later.
- Global left-mouse maps are deleted and `mouse=a` is forced, since the drag-select gesture needs the mouse.
- `lualine` is hidden if present, and `laststatus=0` is kept.
- The compose and note popups are `filetype=markdown`, which pulls in whatever markdown stack is loaded. It's pre-warmed on a throwaway buffer so it doesn't load inside the first keypress.
- The empty-composer check knows two composer shapes: the text between the last two horizontal rules (Claude Code, pi), or a `›` prompt below them through its shaded block (Codex). It's empty when that holds nothing but faint text and one leading `❯`, `›` or `>`. Other agents, and anything it can't place, get a leading blank line above the annotations (a space before a one-line review).

## License

[Apache-2.0](LICENSE), the same as herdr.
