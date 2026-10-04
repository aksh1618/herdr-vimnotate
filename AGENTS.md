# herdr-vimnotate

A herdr plugin that opens the focused pane's scrollback in nvim, in that pane's own layout slot, lets the user annotate it with vim motions, and pastes the review unsubmitted into the agent's composer. The README is the user-facing spec (keys, send format, settings); this file is for changing the code.

Machine-specific notes, if present: @AGENTS.local.md

## Files

- `open.sh`: the plugin action. Expires old restore state, captures `lines` of the pane (`visible` + `recent-unwrapped` ANSI), opens the plugin pane, does the two `pane move`s.
- `herdr-vimnotate.sh`: the plugin pane. Alternate screen, geometry re-apply, runs nvim (handing it `view`, `action_bar` and `restore` as `VIMNOTATE_VIEW`, `VIMNOTATE_ACTION_BAR`, `VIMNOTATE_RESTORE`), moves the target back, sends the review or falls back to the clipboard.
- `vimnotate.lua`: the entry point loaded with `luafile`. Registers every file in `lua/vimnotate/` in `package.preload` by its absolute path, clearing any cached copy, then requires `vimnotate`. Preload runs before the `runtimepath` searcher and `vim.loader`, so a module of the same name elsewhere can't shadow these.
- `lua/vimnotate/`: the nvim session, one module per area.
  - `init.lua`: the facade `M` (what `require("vimnotate")` returns), the setup order, restore, the selected-text anchor and the deferred startup passes.
  - `core.lua`: env paths, global options, the thread buffer and its window, the note buffer/window state, `view` state, `KINDS`, the operator keys (`keys`, checked against `FIXED_KEYS`, `BUFFER_SWITCHERS` and `BUILTIN_KEYS`) and small range helpers.
  - `ansi.lua`: SGR parsing into text lines and highlight spans.
  - `highlights.lua`: the `Vimnotate*` highlight groups.
  - `store.lua`: the annotation store `A`, undo/redo history `H`.
  - `chrome.lua`: location list, winbar, statusline/lualine hiding, markdown pre-warm, `TRIGGERS` and `unshadow_triggers()`.
  - `bars.lua`: the floating action and hint bars, mouse tracking and click dispatch.
  - `compose.lua`: the compose popup.
  - `ops.lua`: operators, `.` repeat, annotation jumps, hover, edit and remove.
  - `boxes.lua`: text layout for the boxes (wrap, truncate, frame, bubble).
  - `rail.lua`: the side rail, its pinned note and its keys.
  - `view.lua`: inline boxes, choosing and applying the view, the winbar flash.
  - `note.lua`: the note popup.
  - `restore.lua`: matching saved annotations back into the thread, writing the restore state.
  - `send.lua`: the reply format and writing `reply.md` on exit.
  - `keys.lua`: the thread buffer's keymaps.
- `config.awk`: the one reader of `$HERDR_PLUGIN_CONFIG_DIR/config.toml`. `awk -v key=<name> -f config.awk <file>` prints that key's value, or its default when missing or invalid. A key under a table header is named with its table (`keys.comment` for `comment` under `[keys]`); tables it doesn't know are skipped. Both scripts use it; nvim never reads the file.
- `composer-empty.awk`: decides whether the agent's composer is empty, from the shapes Claude Code, pi and Codex draw. Anything it does not recognise counts as non-empty.
- `tests/`: `run.sh` runs `cases.lua` through `lib.lua` in headless `nvim --clean`.

## Test

```sh
tests/run.sh
```

All tests must pass before committing. A new case is a `function C.<name>(V)` in `tests/cases.lua` plus a `vn <capture> <state.json> <name>` line in `tests/run.sh`; fixtures go in `tests/fixtures/`. `lib.lua` has the helpers (`T.keys`, `T.mouse`, `T.add`, `T.items`, `T.eq`, `T.finish`).

For anything visual, also run it in a real terminal under termctrl, launched the way `herdr-vimnotate.sh` does:

```sh
VIMNOTATE_RAW=thread.ansi VIMNOTATE_REPLY=/tmp/x/reply.md VIMNOTATE_STATE=/tmp/x/state.json VIMNOTATE_SELECTED=/dev/null VIMNOTATE_VIEW=rail \
  nvim -i NONE -c "luafile $PWD/vimnotate.lua"
```

That loads the user's own nvim config, which is where most breakage shows up. Never drive the user's live herdr session; use `herdr --session <name>` with `HERDR_*` unset. The plugin link and the plugin config dir are not per session (they live under `$XDG_CONFIG_HOME/herdr`), so also point `XDG_CONFIG_HOME` and `XDG_STATE_HOME` at a scratch dir, on a short path: the session socket lives there and must fit `sun_path`.

## Code rules

- **No comments in code.** Rationale goes in commit messages or the README.
- **Modules define, `setup()` registers.** Apart from `core.lua`, which sets the global options and creates the thread buffer as it loads, loading a module only defines functions, constants and namespaces; session-wide autocmds, keymaps, `on_key` handlers and `on_change` listeners are registered in its `setup()`, which `init.lua` calls in a fixed order. Handlers tied to a buffer that comes and goes (the compose popup, the rail, the note) are registered when that buffer is created. Autocmds on the same event run in that order, and namespace ids follow the load order, so keep both when adding one.
- **No cyclic top-level `require`s.** A module may require only modules `init.lua` loads before it. A call that would point the other way goes through the facade at call time (`M.compose(...)`, `M.apply_view()`), and every such function is assigned on `M`.
- **Shared state has one owner.** Read and write it through the owning module's table (`core.note.buf`, `chrome.markdown_warm`, the bars module's `swallow` and `pending_click`); never copy a value that changes into another module's local.
- **Change annotations only through the store** (`M.annotations`: `add`/`update`/`remove`). Undo, the location list, the winbar, the rail and the inline boxes all hang off `on_change`; editing extmarks directly bypasses all of them.
- **Every new thread key goes into `core.FIXED_KEYS`**, which feeds `M.TRIGGERS` and the check that refuses it as an operator key. `unshadow_triggers()` deletes global maps that extend a trigger (a surround plugin's `cs`, `ds`), because a buffer-local exact match does not escape the `timeoutlen` wait. It re-runs, coalesced, after every lazy.nvim `LazyLoad`. Maps are also `nowait`.
- **Operator keys come from `core.keys`, never literals.** A key in `core.TEXTOBJ_PREFIXES` (`a`, `i`) is mapped in normal mode only; its line form is a buffer-local o-mode `aa` that `operator()` adds and the next mode change out of operator-pending removes, so other operators keep `aa`/`af` text objects and x/o-mode maps starting with it are never unshadowed. The action bar runs operators through `<Plug>(vimnotate-<kind>)`, which works for every key.
- **Keep `.` working.** Operators go through `operatorfunc`/`g@`. After a compose popup closes, `M.restore_repeat()` replays the operator so `.` points back at it instead of at the popup's insert.

## Invariants

- **The thread is a normal, non-modifiable buffer** with ANSI parsed into extmarks, not a terminal buffer. A terminal buffer pre-maps the mouse and cancels visual mode on `nvim_set_current_win`.
- **The thread must look identical to the pane until the first annotation.** No rail, no width change, no sign column. `wrap` on and `linebreak` off reproduce the pane's soft-wrap.
- **Capture before the split; resize after every move.** A split rewraps the target, and `pane move` never re-applies geometry, so each pane landing in the slot gets `pane resize --direction right --amount 0`. The vimnotate pane's resize must come from inside the alternate screen, or it settles one scrollbar column narrow.
- **Send with `pane.send_input`, never `send-text`** (every newline in `send-text` submits). Never submit. Prefix a separator only when the composer isn't known to be empty.
- **A review must never be lost.** `reply.md` is written before the restore state. Any send failure falls back to the clipboard, and with no clipboard tool the review file is kept and its path is shown.
- **Privacy:** nvim runs with `-i NONE` (no ShaDa) and `undofile` off. Restore state is `0600` in a `0700` dir (`$HERDR_PLUGIN_STATE_DIR`, else `$XDG_STATE_HOME/vimnotate`), named by a hash of `HERDR_SOCKET_PATH` plus the pane id, because pane ids repeat across herdr servers.
- **Restore matching:** whitespace-insensitive, scored by up to five non-blank context lines each side, ties broken by occurrence index. Text under 8 characters (`strchars`, not bytes) needs a context match, and a linewise item must span whole lines. Unfound items are carried forward, not dropped.
- **Mouse gestures hold the thread's `scrolloff` at 0** until the next non-mouse key; otherwise a press near the edge scrolls the view and the drag lands on later lines.
- **The compose popup reserves blank `virt_lines` under its range** and floats over them, so it never covers thread text, and saving swaps the reservation for the box without movement. `nvim_win_text_height` doesn't count `virt_lines` below its end row.
- **Popups are `filetype=markdown`.** Set `conceallevel` on the window before the filetype (obsidian.nvim warns otherwise), and pre-warm the markdown stack on a throwaway buffer, never on a real one.

## Testing traps

- Headless `feedkeys(…, "mx")` ends insert mode when the keys run out. Code run via `vim.schedule` needs a `vim.wait` before checking.
- `nvim_input_mouse` only works between scheduled steps (`T.mouse` spaces them).
- termctrl: `resize` doesn't reach nvim, so use `:set columns=`; sleep ~0.3 s after `escape` before a mouse event, or it arrives as Alt-click; letters go as `text:j`.
- A user's nvim config can set `cmdheight=0` (echo invisible), a non-zero `scrolloff`, and lazy-loaded maps that extend thread keys.
- `herdr pane get` writes its error JSON to stderr.
- Match processes by exe path, not `pkill -f`, which matches your own shell.

## Demo video

`docs/vimnotate-demo.mp4` is a termctrl recording of a scripted take in an isolated herdr session; the recording scripts are kept outside this repo. `docs/vimnotate-demo.webp` is one frame of it with a play button drawn on, used as the README's poster. Re-record both after any visible UI change.

## Commits

`<area>: <short lowercase subject saying what changed>`, e.g. `ui-ux: hold scrolloff at 0 during mouse gestures`. Areas:

- `ui-ux`: anything the user sees or types in the thread and popups
- `perf`: latency and memory
- `layout`: taking and giving back the pane's slot (`pane move`, geometry)
- `send`: the reply format and delivery, clipboard fallback
- `restore`: saved state and re-anchoring sent annotations
- `plugin`: manifest, id, env vars, `config.toml`, plugin dirs
- `compat`: platform and tool differences (macOS, missing commands)
- `refactor`: restructuring code without changing behaviour
- `tests`, `docs`, `agents` (this file)

Leave the body empty unless the change needs explaining, and then keep it to a few short bullets. Stage explicit paths.
