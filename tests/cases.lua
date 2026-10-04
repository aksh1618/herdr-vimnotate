local C = {}

local function newest(A)
  local best
  for _, it in pairs(A.items) do
    if not best or it.seq > best.seq then
      best = it
    end
  end
  return best
end

local function shape(A, it)
  local r = A.range(it)
  return { it.kind, it.body, r.linewise and { r.srow, r.erow } or { r.srow, r.scol, r.erow, r.ecol } }
end

local function pending()
  local ns = vim.api.nvim_get_namespaces()["vimnotate.pending"]
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(require("vimnotate").thread, ns, 0, -1, { details = true })) do
    out[#out + 1] = { m[2], m[4].end_row, m[4].hl_group }
  end
  return out
end

local function state_items()
  local f = assert(io.open(vim.env.VIMNOTATE_STATE, "rb"))
  local data = vim.json.decode(f:read("*a"))
  f:close()
  return data.items
end

function C.rep_save()
  T.add(T.row("⏺ Read 1 file", 2), "comment", "why read this one?")
  T.finish()
end

function C.rep_same(V)
  T.eq(T.items(), { { kind = "comment", body = "why read this one?", sent = true, lw = true, at = { 5, 5 } } }, "repeated line restores onto the saved occurrence")
  T.eq(V.export(), "", "restored items are not exported")
  T.finish("Cancel")
end

function C.rep_shifted()
  local row = T.row("⏺ Read 1 file", 3)
  T.eq(T.items(), { { kind = "comment", body = "why read this one?", sent = true, lw = true, at = { row, row } } }, "repeated line follows its context after new output above")
  T.finish("Cancel")
end

function C.lw_save()
  T.add(T.row("make test"), "good")
  T.finish()
end

function C.lw_missing(V)
  T.eq(T.items(), {}, "linewise item does not restore inside a longer line")
  T.eq(V.view.flash, "restored 0 sent, 1 not found", "reported as not found")
  T.finish()
end

function C.short_save()
  T.add(T.row("yes"), "good")
  T.finish()
end

function C.short_missing()
  T.eq(T.items(), {}, "short text beside blank lines needs a context match")
  T.finish()
end

function C.short_back()
  T.eq(T.items(), { { kind = "good", body = "", sent = true, lw = true, at = { 2, 2 } } }, "unfound item was carried forward and restores later")
  T.finish("Cancel")
end

function C.emo_save()
  T.add(1, "good")
  T.finish()
end

function C.emo_missing()
  T.eq(T.items(), {}, "emoji text counts characters, not bytes")
  T.finish("Cancel")
end

function C.ro_send()
  T.add(T.row("Done."), "comment", "please fix")
  T.finish()
end

function C.corrupt_unversioned()
  T.eq(T.items(), {}, "corrupt or unversioned state is ignored")
  T.finish("Cancel")
end

function C.corrupt_entries(V)
  T.eq(T.items(), { { kind = "good", body = "", sent = true, lw = true, at = { 7, 7 } } }, "bad entries skipped, valid one restored")
  T.eq(V.history.muted, false, "undo is not left muted")
  T.finish("Cancel")
end

function C.off_add()
  T.eq(T.items(), {}, "restore disabled shows nothing")
  T.add(T.row("Now the tests."), "good")
  T.finish()
end

function C.off_count()
  T.eq(#T.items(), 1, "restore disabled does not duplicate carried items")
  T.eq(#state_items(), 1, "state file holds one entry")
  T.finish("Cancel")
end

function C.server_mismatch()
  T.eq(T.items(), {}, "state from another server is ignored")
  T.finish("Cancel")
end

function C.perms_save()
  T.add(0, "comment", "x")
  T.finish()
end

function C.rekind_save()
  T.add(1, "good")
  T.add(3, "delete", "drop it")
  T.add(5, "comment", "hmm")
  T.finish()
end

function C.rekind(V, A)
  local H = V.history
  local function at(row)
    return A.at(row, 0)
  end
  T.eq(#T.items(), 3, "three sent items restored")
  T.cursor(1)
  T.keys("dd")
  T.eq({ #at(1), at(1)[1].kind, at(1)[1].sent or false, #H.undo }, { 1, "delete", false, 1 }, "d re-kinds a sent good in place")
  T.keys("u")
  T.eq({ at(1)[1].kind, at(1)[1].sent }, { "good", true }, "undo restores the sent good")
  T.keys("<C-r>")
  T.eq({ at(1)[1].kind, at(1)[1].sent or false }, { "delete", false }, "redo re-applies")
  T.keys("u")
  T.cursor(3)
  local before = #H.undo
  T.keys("cc")
  local c = V.composing()
  T.eq({ c and c.kind, c and c.item and c.item.body }, { "comment", "drop it" }, "c on a sent delete composes on that item")
  T.keys("A more<CR>")
  T.eq({ #at(3), at(3)[1].kind, at(3)[1].body, at(3)[1].sent or false, #H.undo - before }, { 1, "comment", "drop it more", false, 1 }, "kind and body change in one undo step")
  T.keys("u")
  T.eq({ at(3)[1].kind, at(3)[1].body, at(3)[1].sent }, { "delete", "drop it", true }, "undo restores kind, body and sent")
  T.cursor(1)
  T.keys("cc<CR>")
  T.eq({ #at(1), at(1)[1].kind, at(1)[1].sent }, { 1, "good", true }, "empty compose leaves a sent good untouched")
  T.cursor(1)
  T.keys("pp")
  T.eq({ #at(1), at(1)[1].kind, at(1)[1].sent or false }, { 1, "good", false }, "same kind only un-sends")
  T.cursor(5)
  T.keys("ccsecond<CR>")
  T.eq(#at(5), 2, "c on a sent comment adds a new comment")
  T.cursor(3)
  T.keys("pp")
  T.eq({ #at(3), at(3)[1].kind }, { 1, "good" }, "p re-kinds a sent delete")
  T.finish("Cancel")
end

function C.format(V)
  local win = V.note_open()
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { "", "general note", "" })
  local A = V.annotations
  A.add({ srow = 0, scol = 0, erow = 1, ecol = 0, linewise = true, kind = "comment", body = "first comment\n\n> quoted-looking line\n  >> nested" })
  T.addchar(2, 5, 10, "good")
  T.add(3, "good", "nice\nreally")
  T.add(4, "delete")
  T.add(5, "delete", "too long")
  T.add(6, "delete", "a\nb")
  A.add({ srow = 6, scol = 0, erow = 8, ecol = 0, linewise = true, kind = "comment", body = "multi" })
  T.add(9, "good", "", true)
  local f = assert(io.open(vim.env.VIMNOTATE_RAW:gsub("ops%.txt$", "format.expected"), "rb"))
  local want = f:read("*a"):gsub("\n$", "")
  f:close()
  T.eq(V.export(), want, "export bytes")
  T.finish()
end

function C.operators(V, A)
  local cases = {
    { 0, "ccone<CR>", { "comment", "one", { 0, 0 } } },
    { 1, "2Ctwo<CR>", { "comment", "two", { 1, 2 } } },
    { 3, "Cthree<CR>", { "comment", "three", { 3, 3 } } },
    { 4, "3ccfour<CR>", { "comment", "four", { 4, 6 } } },
    { 8, "dd", { "delete", "", { 8, 8 } } },
    { 9, "2dd", { "delete", "", { 9, 10 } } },
    { 11, "d2j", { "delete", "", { 11, 13 } } },
    { 14, "pp", { "good", "", { 14, 14 } } },
    { 15, "3pp", { "good", "", { 15, 17 } } },
    { 18, "dw", { "delete", "", { 18, 0, 18, 5 } } },
    { 19, "pe", { "good", "", { 19, 0, 19, 4 } } },
    { 20, "c$end<CR>", { "comment", "end", { 20, 5, 20, 7 } }, 5 },
    { 21, "cwword<CR>", { "comment", "word", { 21, 0, 21, 5 } } },
  }
  for _, c in ipairs(cases) do
    T.cursor(c[1], c[4] or 0)
    T.keys(c[2])
    T.eq(shape(A, newest(A)), c[3], c[2] .. " on row " .. c[1])
  end
  T.eq(V.composing(), nil, "no compose left open")
  T.finish("Cancel")
end

function C.visual(V, A)
  local cases = {
    { 0, "vjd", { "delete", "", { 0, 0, 1, 1 } } },
    { 2, "Vjp", { "good", "", { 2, 3 } } },
    { 4, "vecx<CR>", { "comment", "x", { 4, 0, 4, 4 } } },
    { 5, "VCy<CR>", { "comment", "y", { 5, 5 } } },
    { 6, "veCz<CR>", { "comment", "z", { 6, 0, 6, 4 } } },
    { 8, "Vjjc<CR>", nil },
  }
  for _, c in ipairs(cases) do
    T.cursor(c[1])
    local n = vim.tbl_count(A.items)
    T.keys(c[2])
    if c[3] then
      T.eq(shape(A, newest(A)), c[3], c[2] .. " on row " .. c[1])
    else
      T.eq(vim.tbl_count(A.items), n, c[2] .. " with an empty comment adds nothing")
    end
  end
  T.finish("Cancel")
end

function C.dot_repeat(V, A)
  T.cursor(0)
  T.keys("ccalpha<CR>")
  T.cursor(2)
  T.keys(".<CR>")
  T.eq(shape(A, newest(A)), { "comment", "alpha", { 2, 2 } }, "cc . repeats with the last body")
  T.cursor(4)
  T.keys("3Cbeta<CR>")
  T.cursor(10)
  T.keys(".<CR>")
  T.eq(shape(A, newest(A)), { "comment", "beta", { 10, 12 } }, "3C . repeats three lines")
  T.cursor(14)
  T.keys("2dd")
  T.cursor(17)
  T.keys(".")
  T.eq(shape(A, newest(A)), { "delete", "", { 17, 18 } }, "2dd . repeats")
  T.cursor(20)
  T.keys("dw")
  T.cursor(21)
  T.keys(".")
  T.eq(shape(A, newest(A)), { "delete", "", { 21, 0, 21, 5 } }, "dw . repeats")
  T.cursor(23)
  T.keys("Vjp")
  T.cursor(26)
  T.keys(".")
  T.eq(shape(A, newest(A)), { "good", "", { 26, 27 } }, "visual Vjp . repeats two lines")
  T.finish("Cancel")
end

function C.undo_redo(V, A)
  local function count()
    return vim.tbl_count(A.items)
  end
  T.cursor(0)
  T.keys("dd")
  T.cursor(1)
  T.keys("pp")
  T.eq(count(), 2, "two added")
  T.keys("u")
  T.eq(count(), 1, "u undoes one add")
  T.keys("u")
  T.eq(count(), 0, "u undoes the other")
  T.keys("u")
  T.eq(V.view.flash, "nothing to undo", "empty undo stack reported")
  T.keys("2<C-r>")
  T.eq(count(), 2, "count redo")
  T.cursor(0)
  T.keys("x")
  T.eq(count(), 1, "x removes")
  T.keys("u")
  T.eq(count(), 2, "u restores a removed item")
  T.cursor(1)
  T.keys("eedited<CR>")
  T.eq(A.at(1, 0)[1].body, "edited", "e edits")
  T.keys("u")
  T.eq(A.at(1, 0)[1].body, "", "u undoes an edit")
  T.keys("<C-r>")
  T.eq(A.at(1, 0)[1].body, "edited", "redo re-applies an edit")
  T.cursor(3)
  T.keys("ccnew<CR>")
  T.keys("u")
  T.eq(#A.at(3, 0), 0, "u undoes a composed comment")
  T.finish("Cancel")
end

function C.compose_highlight(V, A)
  T.cursor(2)
  T.keys("cc")
  T.eq(pending(), { { 2, 3, "VimnotateCommentActive" } }, "range highlighted while composing a new comment")
  T.keys("q")
  T.eq({ pending(), vim.tbl_count(A.items) }, { {}, 0 }, "cancel clears the highlight")
  T.cursor(2)
  T.keys("cchi<CR>")
  local mark = vim.api.nvim_buf_get_extmark_by_id(V.thread, A.range_ns, newest(A).mark, { details = true })
  T.eq({ pending(), mark[3].hl_group }, { {}, "VimnotateComment" }, "save hands over to the saved highlight")
  T.keys("e")
  T.eq(pending(), { { 2, 3, "VimnotateCommentActive" } }, "e highlights a comment")
  T.keys("<Esc>q")
  T.cursor(4)
  T.keys("dd")
  T.keys("e")
  T.eq(pending(), { { 4, 5, "VimnotateDeleteActive" } }, "e highlights a delete in its kind")
  T.keys("<Esc>q")
  T.cursor(6)
  T.keys("pp")
  T.keys("e")
  T.eq(pending(), { { 6, 7, "VimnotateGoodActive" } }, "e highlights a looks-good in its kind")
  T.keys("<Esc>q")
  T.eq(pending(), {}, "all cleared")
  T.finish("Cancel")
end

function C.anchor_highlight(V)
  T.eq(pending(), { { 2, 2, "VimnotateCommentActive" } }, "startup selection anchor is highlighted")
  T.ok(V.composing() ~= nil, "compose open at startup")
  T.finish("Cancel")
end

function C.hover_sent(V)
  T.add(2, "good", "fine", true)
  T.cursor(2)
  V.hover()
  local title
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= "" and cfg.title then
      title = ""
      for _, chunk in ipairs(cfg.title) do
        title = title .. chunk[1]
      end
    end
  end
  T.ok(title and title:find("· sent", 1, true) ~= nil, "K title marks a sent item: " .. tostring(title))
  T.finish("Cancel")
end

function C.no_repeat_provider(V, A)
  T.add(2, "good")
  T.add(5, "good")
  T.cursor(0)
  T.keys("]a")
  T.eq(vim.api.nvim_win_get_cursor(0), { 3, 0 }, "]a jumps")
  T.keys("fe;")
  T.eq(vim.api.nvim_win_get_cursor(0), { 3, 8 }, "; still repeats f without a provider")
  T.eq(vim.fn.maparg(";", "n"), "", "; is left unmapped")
  T.finish("Cancel")
end

function C.repeat_provider(V, A)
  T.add(2, "good")
  T.add(5, "good")
  T.add(9, "good")
  T.cursor(0)
  T.keys("]a")
  T.keys(";")
  T.eq(vim.api.nvim_win_get_cursor(0), { 6, 0 }, "; repeats ]a")
  T.keys(";")
  T.eq(vim.api.nvim_win_get_cursor(0), { 10, 0 }, "; again")
  T.keys(",")
  T.eq(vim.api.nvim_win_get_cursor(0), { 6, 0 }, ", goes back")
  T.keys("[a;")
  T.eq(vim.api.nvim_win_get_cursor(0), { 6, 0 }, "; after [a still goes forward")
  T.cursor(2)
  T.keys("fe;")
  T.eq(vim.api.nvim_win_get_cursor(0), { 3, 8 }, "; repeats f after ]a")
  T.finish("Cancel")
end

local function note_lines()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match("/note%.md$") then
      return vim.api.nvim_buf_get_lines(b, 0, -1, false)
    end
  end
  return nil
end

local function settle()
  vim.wait(30, function()
    return false
  end)
end

local function layout()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      out[#out + 1] = { w, vim.api.nvim_win_get_width(w), vim.api.nvim_win_get_height(w) }
    end
  end
  return out
end

local function title_of(cfg)
  local t = ""
  for _, chunk in ipairs(cfg.title or {}) do
    t = t .. chunk[1]
  end
  return t
end

function C.q_guard(V)
  T.cursor(0)
  T.keys("cc<Esc>q")
  T.eq({ vim.api.nvim_get_current_win(), V.q_guarded() }, { V.thread_win(), true }, "cancelling the compose popup arms the guard")
  T.keys("q")
  T.ok(vim.wo[V.thread_win()].winbar:find("q sends", 1, true) ~= nil, "a q right after it flashes instead of sending")
  vim.wait(450)
  T.ok(not V.q_guarded(), "the guard lapses")
  T.keys("<Tab>x<Esc>q")
  T.ok(V.q_guarded(), "hiding the note arms it too")
  vim.wait(450)
  T.keys("jk")
  T.ok(not V.q_guarded(), "moving in the thread does not arm it")
  local exits = 0
  local real = vim.cmd
  vim.cmd = setmetatable({}, {
    __call = function(_, c)
      if c == "qa" then
        exits = exits + 1
        return
      end
      return real(c)
    end,
    __index = real,
  })
  T.keys("q")
  vim.cmd = real
  T.eq(exits, 1, "a later q sends")
  T.finish("Cancel")
end

function C.note_toggle(V, A)
  T.cursor(0)
  T.keys("<Tab>line one<CR>line two<Esc>")
  T.ok(V.note_shown(), "Tab opens the note in insert mode")
  local cfg = vim.api.nvim_win_get_config(0)
  T.eq({ cfg.relative, cfg.border[1] }, { "editor", "╭" }, "note is a floating popup with a rounded border")
  T.ok(vim.wo.winhighlight:find("FloatBorder:VimnotateCommentBorder", 1, true) ~= nil, "border uses the comment accent")
  T.eq(note_lines(), { "line one", "line two" }, "insert Enter is a newline")
  T.keys("q")
  T.eq({ V.note_shown(), vim.api.nvim_get_current_win() == V.thread_win() }, { false, true }, "q hides and returns to the thread")
  T.ok(vim.wo[V.thread_win()].winbar:find("✎ note", 1, true) ~= nil, "winbar marks a non-empty note")
  T.keys("<Tab>")
  T.eq({ V.note_shown(), vim.fn.mode(), vim.api.nvim_win_get_cursor(0) }, { true, "n", { 2, 7 } }, "a non-empty note opens in normal mode at the end")
  T.keys("a!<Esc><Tab>")
  T.eq({ V.note_shown(), note_lines() }, { false, { "line one", "line two!" } }, "Tab hides and keeps the content")
  T.keys("<Tab>")
  T.add(4, "good")
  T.finish()
end

function C.note_empty(V)
  T.cursor(0)
  T.keys("<Tab>   <CR><CR><Esc>q")
  T.ok(vim.wo[V.thread_win()].winbar:find("✎", 1, true) == nil, "blank note is not marked")
  T.eq(V.export(), "", "blank note exports nothing")
  T.add(1, "delete")
  T.eq(V.export(), "> line two\n\nRemove this.", "blank note adds no leading block")
  T.finish()
end

function C.note_none()
  T.cursor(0)
  T.keys("<Tab><Esc>q")
  T.finish()
end

function C.note_fallback(V)
  T.eq(note_lines(), { "> not in the thread", "> second line", "", "" }, "unfound selection is quoted into the note")
  T.eq({ V.note_shown(), vim.api.nvim_get_current_win() ~= V.thread_win(), vim.api.nvim_win_get_cursor(0)[1] }, { true, true, 4 }, "note popup open below the quote")
  T.keys("ireply here<Esc>")
  T.finish()
end

local function clip_files()
  local p = vim.env.VIMNOTATE_CLIPBOARD
  return { vim.uv.fs_stat(p) ~= nil, vim.uv.fs_stat(p .. ".used") ~= nil }
end

function C.clip_anchor(V)
  T.eq(pending(), { { 2, 2, "VimnotateCommentActive" } }, "clipboard text found in the thread anchors the compose popup")
  T.ok(V.composing() ~= nil, "compose open at startup")
  T.eq(clip_files(), { false, true }, "clipboard file removed, use recorded")
  T.finish("Cancel")
end

function C.clip_unfound(V)
  T.eq(pending(), {}, "clipboard text not in the thread anchors nothing")
  T.ok(V.composing() == nil, "no compose popup")
  local nl = note_lines()
  T.ok(not V.note_shown() and (nl == nil or table.concat(nl) == ""), "clipboard text is never quoted into the note")
  T.eq(clip_files(), { false, false }, "clipboard file removed, no use recorded")
  T.finish("Cancel")
end

function C.clip_short(V)
  T.eq(pending(), {}, "clipboard text under 8 characters anchors nothing")
  T.ok(V.composing() == nil, "no compose popup")
  T.finish("Cancel")
end

function C.clip_after_selection(V)
  T.eq(pending(), {}, "a copy-mode selection wins over the clipboard")
  T.eq(note_lines(), { "> not in the thread", "> second line", "", "" }, "the selection is still quoted into the note")
  T.eq(clip_files(), { true, false }, "clipboard left unread")
  T.finish("Cancel")
end

function C.note_cancel()
  T.cursor(0)
  T.keys("<Tab>keep me<Esc>q")
  T.add(2, "good")
  T.finish("Cancel")
end

function C.note_layout(V, A)
  V.view.setting = "rail"
  vim.o.columns = 160
  vim.o.lines = 50
  T.add(2, "good")
  T.add(6, "comment", "hm")
  settle()
  local before = layout()
  T.eq(#before, 2, "rail is open")
  T.cursor(0)
  T.keys("<Tab>")
  local cfg = vim.api.nvim_win_get_config(0)
  T.eq({ cfg.width, cfg.height, cfg.row, cfg.col }, { 100, 22, 12, 29 }, "160x50: centred, width capped")
  T.ok(vim.fn.strdisplaywidth(title_of(cfg)) <= cfg.width, "title fits: " .. title_of(cfg))
  T.eq(title_of(cfg), " note · sent first · q/Tab close · i insert ", "160: full normal-mode title")
  T.eq({ cfg.footer, cfg.footer_pos }, { nil, nil }, "no footer")
  T.eq(layout(), before, "thread and rail keep their size with the note open")
  vim.o.columns = 80
  vim.o.lines = 24
  settle()
  cfg = vim.api.nvim_win_get_config(0)
  T.eq({ cfg.width, cfg.height, cfg.row, cfg.col }, { 56, 10, 5, 11 }, "80x24: recomputed on resize")
  T.ok(vim.fn.strdisplaywidth(title_of(cfg)) <= cfg.width, "title fits at 80 columns")
  T.eq(title_of(cfg), " note · sent first · q/Tab close · i insert ", "80: full normal-mode title")
  vim.o.columns = 30
  settle()
  cfg = vim.api.nvim_win_get_config(0)
  T.eq(cfg.width, 28, "never wider than the editor")
  T.ok(vim.fn.strdisplaywidth(title_of(cfg)) <= cfg.width, "title truncated to fit")
  T.eq(title_of(cfg), " note · q/Tab close ", "30: drops sent first and i insert, keeps the close hint")
  T.eq(V.note_title(12), " note · q/T…", "narrower still: truncated")
  T.finish("Cancel")
end

function C.note_focus(V)
  T.cursor(0)
  T.keys("<Tab>x<Esc>")
  local other = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, { relative = "editor", row = 0, col = 0, width = 5, height = 1 })
  settle()
  T.ok(V.note_shown(), "entering another float keeps the note")
  vim.api.nvim_win_close(other, true)
  vim.api.nvim_set_current_win(V.thread_win())
  settle()
  T.eq({ V.note_shown(), note_lines() }, { false, { "x" } }, "leaving for the thread hides it and keeps the text")
  T.keys("<Tab>")
  T.ok(V.note_shown(), "Tab reopens")
  T.finish("Cancel")
end

function C.popup_undo(V)
  T.cursor(0)
  T.keys("<Tab>abc<Esc>u")
  T.eq(note_lines(), { "" }, "u undoes inside the note")
  T.keys("q")
  T.cursor(1)
  T.keys("ccabc<Esc>uiX<CR>")
  T.eq(V.annotations.at(1, 0)[1].body, "X", "u undoes inside the compose popup")
  T.finish("Cancel")
end

function C.compose_full_row(V)
  T.cursor(1)
  local c, w
  local function state()
    vim.cmd("redraw")
    local view = vim.api.nvim_win_call(c.win, vim.fn.winsaveview)
    return { vim.api.nvim_get_mode().mode, vim.api.nvim_win_get_height(c.win), view.topline, view.skipcol }
  end
  local steps = {
    { "cc", function()
      c = V.composing()
      w = vim.api.nvim_win_get_width(c.win)
      vim.api.nvim_input("a" .. string.rep("x", w - 2))
    end },
    { nil, function()
      T.eq(state(), { "i", 1, 1, 0 }, "one short of a full row stays one row")
    end },
    { "y", function()
      T.eq(state(), { "i", 2, 1, 0 }, "a full row grows for the cursor past its end")
    end },
    { "z", function()
      T.eq(state(), { "i", 2, 1, 0 }, "the next character wraps onto it")
    end },
    { "<BS>", function()
      T.eq(state(), { "i", 2, 1, 0 }, "back at the end of a full row keeps the cursor row")
    end },
    { "<Esc>", function()
      T.eq(state(), { "n", 1, 1, 0 }, "normal mode drops it")
    end },
    { "A", function()
      T.eq(state(), { "i", 2, 1, 0 }, "A at the end of a full row adds it back")
    end },
  }
  local i = 0
  local function nxt()
    i = i + 1
    local s = steps[i]
    if not s then
      return T.finish("Cancel")
    end
    if s[1] then
      vim.api.nvim_input(s[1])
    end
    vim.defer_fn(function()
      s[2]()
      vim.defer_fn(nxt, 30)
    end, 30)
  end
  vim.schedule(nxt)
end

function C.no_undofile()
  T.cursor(0)
  T.keys("<Tab>secret note<Esc>q")
  T.keys("ccsecret comment<CR>")
  T.finish("qa")
end

local function rail_lines(V)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(V.view.rail_win), 0, -1, false)
end

local function set_note(V, text)
  V.note_show()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.cmd("stopinsert")
  V.note_hide()
  settle()
end

local function rail_setup(V)
  V.view.setting = "rail"
  vim.o.columns = 160
  vim.o.lines = 50
  T.add(1, "good")
  T.add(20, "comment", "later")
  settle()
  vim.api.nvim_win_call(V.thread_win(), function()
    vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
  end)
  V.rail_render()
end

function C.note_title_insert(V)
  T.cursor(0)
  local seen
  _G.vimnotate_test_capture = function()
    seen = { vim.fn.mode(), title_of(vim.api.nvim_win_get_config(0)), V.note_title(19) }
  end
  T.keys("<Tab>abc<Cmd>lua vimnotate_test_capture()<CR><Esc>")
  T.eq(seen, { "i", " note · sent first · esc normal ", " note · esc normal " }, "insert-mode title, narrow one drops sent first")
  T.eq(title_of(vim.api.nvim_win_get_config(0)), " note · sent first · q/Tab close · i insert ", "normal-mode title after esc")
  T.finish("Cancel")
end

function C.mode_cue(V)
  local tw = V.thread_win()
  T.eq(vim.api.nvim_win_get_width(tw), vim.o.columns, "thread keeps the full width")
  T.eq({ vim.wo[tw].signcolumn, vim.wo[tw].number, vim.wo[tw].wrap }, { "no", false, true }, "no gutter, wrap kept")
  T.ok(vim.wo[tw].winbar:find("^%%#VimnotateMode# VIMNOTATE %%%*") ~= nil, "winbar opens with the badge: " .. vim.wo[tw].winbar)
  T.eq(vim.wo[tw].winhighlight, "WinBar:VimnotateWinbar,WinBarNC:VimnotateWinbar", "winbar row is tinted")
  local badge = vim.api.nvim_get_hl(0, { name = "VimnotateMode" })
  local bar = vim.api.nvim_get_hl(0, { name = "VimnotateWinbar" })
  T.ok(badge.bg and badge.ctermbg and badge.bold, "badge has gui and cterm colours")
  T.ok(bar.bg and bar.ctermbg and bar.bg ~= badge.bg, "bar tint has gui and cterm colours")
  T.eq(vim.api.nvim_get_hl(0, { name = "MsgArea" }).link, "VimnotateMsgArea", "bottom row follows VimnotateMsgArea")
  local head = vim.api.nvim_eval_statusline(vim.wo[tw].winbar, { winid = tw, use_winbar = true, highlights = true })
  T.eq(head.highlights[1].group, "VimnotateMode", "badge drawn with VimnotateMode")
  T.eq(head.highlights[2].group, "WinBar", "rest of the row falls back to the remapped WinBar")
  vim.o.background = "light"
  local light = vim.api.nvim_get_hl(0, { name = "VimnotateWinbar" }).bg
  T.ok(light ~= bar.bg, "switching to a light background re-tints the bar")
  vim.cmd("hi clear")
  vim.cmd("doautocmd ColorScheme")
  T.eq(vim.api.nvim_get_hl(0, { name = "VimnotateWinbar" }).bg, light, "a colorscheme reload restores it")
  vim.wo[tw].winhighlight = "Normal:ErrorMsg,WinBar:Search"
  require("vimnotate.core").scrub_win(tw)
  T.eq(vim.wo[tw].winhighlight, "Normal:ErrorMsg,WinBar:VimnotateWinbar,WinBarNC:VimnotateWinbar", "other window highlights are kept")
  T.finish("Cancel")
end

function C.mode_cue_override(V)
  T.eq(vim.api.nvim_get_hl(0, { name = "VimnotateMode" }).bg, 0x123456, "a user's own badge colour survives")
  vim.cmd("doautocmd ColorScheme")
  vim.o.background = "light"
  T.eq(vim.api.nvim_get_hl(0, { name = "VimnotateMode" }).bg, 0x123456, "and survives a reload and a background change")
  T.finish("Cancel")
end

function C.note_marker(V)
  local wb = function()
    return vim.wo[V.thread_win()].winbar
  end
  T.ok(wb():find("✎", 1, true) == nil, "no marker without a note")
  set_note(V, "hello")
  T.ok(wb():find("%@v:lua.vimnotate_note_click@%#VimnotateWinbarNote#✎ note%*%T", 1, true) ~= nil, "marker is highlighted and clickable: " .. wb())
  T.ok(wb():find("✎", 1, true) < wb():find("%<", 1, true), "marker sits before the truncation point")
  local mark = vim.api.nvim_get_hl(0, { name = "VimnotateWinbarNote" })
  local accent = vim.api.nvim_get_hl(0, { name = "VimnotateCommentBorder" })
  T.eq({ mark.fg, mark.ctermfg }, { accent.fg, accent.ctermfg }, "marker uses the comment accent")
  vim.o.columns = 80
  settle()
  local head = vim.api.nvim_eval_statusline(wb(), { winid = V.thread_win(), maxwidth = vim.api.nvim_win_get_width(V.thread_win()), use_winbar = true, highlights = true })
  T.ok(head.str:find("✎ note", 1, true) ~= nil, "marker survives truncation at 80 columns: " .. head.str)
  local yellow = false
  for _, h in ipairs(head.highlights) do
    if h.group == "VimnotateWinbarNote" then
      yellow = true
    end
  end
  T.ok(yellow, "marker drawn with VimnotateWinbarNote")
  _G.vimnotate_note_click(0, 1, "r", "    ")
  settle()
  T.ok(not V.note_shown(), "right click does nothing")
  _G.vimnotate_note_click(0, 1, "l", "    ")
  settle()
  T.ok(V.note_shown(), "clicking the marker opens the note")
  V.note_hide()
  T.finish("Cancel")
end

function C.pin_rail(V, A)
  rail_setup(V)
  T.ok(rail_lines(V)[1]:find("✎", 1, true) == nil, "empty note: nothing pinned")
  T.eq(V.view.bubbles[1].y0, 1, "empty note: first bubble at its anchor")
  set_note(V, "first point\nsecond point")
  local lines = rail_lines(V)
  T.ok(lines[1]:find("╭ ✎ note ", 1, true) == 1, "pinned title on row 0: " .. lines[1])
  T.ok(lines[2]:find("first point", 1, true) ~= nil and lines[3]:find("second point", 1, true) ~= nil, "note text inside the bubble")
  T.ok(lines[4]:find("╰", 1, true) == 1, "pinned bubble closes after its text")
  T.eq({ V.view.bubbles[1].item, V.view.bubbles[1].y0, V.view.bubbles[1].y1 }, { V.pin.item, 0, 3 }, "note is the first bubble")
  T.eq(V.view.bubbles[2].y0, 4, "annotation anchored above the pin is pushed below it")
  T.eq(V.view.bubbles[3].y0, 20, "annotation further down keeps its anchor")
  local marks = vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(V.view.rail_win), -1, { 0, 0 }, { 0, -1 }, { details = true })
  local title_hl
  for _, m in ipairs(marks) do
    if m[3] == 3 then
      title_hl = m[4].hl_group
    end
  end
  T.eq(title_hl, "VimnotateCommentBorder", "pinned title in the comment accent")
  vim.api.nvim_win_call(V.thread_win(), function()
    vim.cmd("normal! 10\5")
  end)
  V.rail_render()
  T.ok(rail_lines(V)[1]:find("╭ ✎ note ", 1, true) == 1, "pin does not scroll with the thread")
  T.eq(V.view.bubbles[2].y0, 10, "scrolled annotation keeps its anchor below the pin")
  set_note(V, "1\n2\n3\n4\n5\n6\n7\n8")
  lines = rail_lines(V)
  T.eq({ V.view.bubbles[1].y1, vim.trim(lines[5]:gsub("│", "")) }, { 5, "…" }, "long note capped at 6 rows with an ellipsis")
  T.ok(lines[6]:find("╰", 1, true) == 1, "capped bubble still closes")
  set_note(V, "  ")
  T.ok(rail_lines(V)[1]:find("✎", 1, true) == nil, "blank note unpins")
  V.view.setting = "inline"
  set_note(V, "x")
  V.apply_view()
  T.eq({ V.view.mode, V.view.rail_win and vim.api.nvim_win_is_valid(V.view.rail_win) or false }, { "inline", false }, "inline view has no rail and no pin")
  T.ok(not V.pin.on(), "pin is off in inline view")
  T.finish("Cancel")
end

function C.pin_alone(V)
  V.view.setting = "rail"
  vim.o.columns = 160
  set_note(V, "only a note")
  V.apply_view()
  T.eq(#layout(), 1, "a note alone does not open the rail")
  T.finish("Cancel")
end

function C.pin_nav(V, A)
  rail_setup(V)
  set_note(V, "the note")
  V.rail_focus()
  T.eq(V.view.sel, V.pin.item, "entering the rail with no annotation under the cursor selects the note")
  T.keys("j")
  T.eq(V.view.sel and V.view.sel.kind, "good", "j moves to the first annotation")
  T.keys("k")
  T.eq(V.view.sel, V.pin.item, "k moves back to the note")
  T.keys("k")
  T.eq(V.view.sel, V.pin.item, "k stops at the note")
  T.keys("G")
  T.eq(V.view.sel and V.view.sel.kind, "comment", "G goes to the last annotation")
  T.keys("gg")
  T.eq(V.view.sel, V.pin.item, "gg goes to the note")
  local edge
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, { 0, 0 }, { 0, -1 }, { details = true })) do
    if m[3] == 0 then
      edge = m[4].hl_group
    end
  end
  T.eq(edge, "VimnotateCommentBorderBold", "selected note gets the bold accent edge")
  T.keys("x")
  settle()
  T.eq({ #A.list(), V.note_shown(), vim.api.nvim_get_current_win() == V.view.rail_win }, { 2, false, true }, "x on the note does nothing")
  T.ok(V.pin.on(), "note still pinned after x")
  T.keys("<CR>")
  T.eq({ V.note_shown(), vim.fn.mode() }, { true, "n" }, "enter on the note opens the popup")
  T.keys("q")
  settle()
  T.eq(vim.api.nvim_get_current_win(), V.thread_win(), "closing returns to the thread")
  V.rail_focus()
  T.keys("ggk")
  T.keys("e")
  T.ok(V.note_shown(), "e on the note opens the popup")
  T.keys("A more<Esc>q")
  settle()
  T.ok(rail_lines(V)[2]:find("the note more", 1, true) ~= nil, "pinned bubble updates when the popup closes")
  V.rail_click(2)
  settle()
  T.ok(V.note_shown(), "clicking the pinned bubble opens the popup")
  T.keys("q")
  settle()
  V.rail_click(5)
  T.eq({ V.note_shown(), vim.api.nvim_win_get_cursor(V.thread_win())[1] }, { false, 2 }, "clicking an annotation below still jumps to it")
  T.finish("Cancel")
end

local function near_bottom(V, from)
  local tw = V.thread_win()
  local info = vim.fn.getwininfo(tw)[1]
  local last = info.winrow + info.winbar + info.height - 2
  for l = from, vim.api.nvim_buf_line_count(V.thread) do
    local p = vim.fn.screenpos(tw, l, 1)
    if p.row > 0 and p.row >= last - 2 then
      return l - 1, p.row - 1
    end
  end
end

local function mouse_setup(V, boxes)
  vim.o.scrolloff = 8
  V.view.setting = "inline"
  for _, r in ipairs(boxes) do
    T.add(r, "comment", "box " .. r)
  end
  T.cursor(0)
  vim.cmd("normal! zt")
  V.apply_view()
  vim.cmd("redraw")
end

local function mouse_drag(V, boxes, done)
  mouse_setup(V, boxes)
  local row, y = near_bottom(V, (boxes[#boxes] or 0) + 2)
  local top = vim.fn.line("w0")
  T.mouse({ { "press", y, 0 }, { "drag", y, 2 }, { "drag", y, 4 }, { "release", y, 4 } }, function()
    T.eq({ vim.fn.mode(), vim.fn.getpos("v")[2] - 1, vim.fn.getpos(".")[2] - 1 }, { "v", row, row }, "drag on a row near the bottom selects that row")
    T.eq(vim.fn.line("w0"), top, "the thread does not scroll under the mouse")
    done(row)
  end)
end

function C.mouse_scrolloff_bar(V)
  mouse_drag(V, { 1, 3, 5 }, function(row)
    local bar = V.bars.action
    local pos = vim.api.nvim_win_get_position(bar.win)
    local x = pos[2] + bar.spans[2].from + 2
    T.mouse({ { "press", pos[1], x }, { "release", pos[1], x } }, function()
      local c = V.composing()
      T.eq(c and { c.range.srow, c.range.erow } or false, { row, row }, "comment from the action bar anchors on the selected row")
      T.finish("Cancel")
    end)
  end)
end

function C.mouse_scrolloff_plain(V)
  mouse_drag(V, {}, function()
    T.finish("Cancel")
  end)
end

function C.mouse_scrolloff_restore(V)
  mouse_drag(V, { 1 }, function()
    local tw = V.thread_win()
    T.eq(vim.wo[tw].scrolloff, 0, "scrolloff held at 0 after a mouse selection")
    vim.api.nvim_input("<Esc>")
    vim.defer_fn(function()
      T.eq(vim.wo[tw].scrolloff, 8, "the next key restores scrolloff")
      T.finish("Cancel")
    end, 30)
  end)
end

local function config_check(V, mode, bar)
  vim.o.columns = 160
  vim.o.lines = 50
  T.add(1, "good")
  V.apply_view()
  T.eq(V.view.mode, mode, "view from the config")
  T.cursor(3)
  vim.api.nvim_input("V")
  vim.defer_fn(function()
    T.eq(V.bars.action.win ~= nil and vim.api.nvim_win_is_valid(V.bars.action.win), bar, "action bar from the config")
    vim.api.nvim_input("<Esc>")
    vim.defer_fn(function()
      T.finish("Cancel")
    end, 30)
  end, 50)
end

function C.config_defaults(V)
  config_check(V, "inline", true)
end

function C.config_set(V)
  config_check(V, "rail", false)
end

function C.hint_bar(V)
  T.add(1, "good")
  T.add(3, "comment")
  local bar = V.bars.hint
  vim.defer_fn(function()
    T.cursor(2)
    T.keys("j")
  end, 300)
  vim.defer_fn(function()
    T.eq(bar.win ~= nil and vim.api.nvim_win_is_valid(bar.win), true, "hint bar shown on an annotation")
    T.eq(vim.api.nvim_buf_get_lines(bar.buf, 0, -1, false)[1], " 📝 edit (e)  🧹 remove (x) ", "hint bar text, no show for a visible box")
    T.eq(vim.tbl_map(function(s)
      return { s.from, s.to, s.hl }
    end, bar.spans), { { 0, 13, "VimnotateBarComment" }, { 13, 28, "VimnotateBarComment" } }, "hint spans by display width, in the accent colour")
    T.eq({ bar.width, vim.api.nvim_win_get_width(bar.win) }, { 28, 28 }, "hint bar width")
    T.eq(V.bars.pieces({ { glyph = "👍", label = "looks good", key = "p" } }, "X")[1].text, " 👍 looks good (p) ", "shared piece format")
    local pos = vim.api.nvim_win_get_position(bar.win)
    local x = pos[2] + bar.spans[2].from + 6
    T.mouse({ { "press", pos[1], x }, { "release", pos[1], x } }, function()
      T.eq(#T.items(), 1, "clicking remove drops the annotation under the cursor")
      T.eq(T.items()[1].at, { 1, 1 }, "the other annotation stays")
      T.finish("Cancel")
    end)
  end, 700)
end

function C.keys_resolve()
  local core = require("vimnotate.core")
  local function try(env)
    local keys, warning = core.resolve_keys(env)
    return { keys.comment .. keys.delete .. keys.good, warning ~= nil }
  end
  T.eq(try({}), { "cdp", false }, "no settings: defaults")
  T.eq(try({ comment = "m", delete = "s", good = "a" }), { "msa", false }, "three free keys")
  T.eq(try({ comment = "d", delete = "c" }), { "dcp", false }, "swapped defaults")
  T.eq(try({ comment = "%", good = "i" }), { "%di", false }, "punctuation and i")
  for _, bad in ipairs({ "aa", "", "é", " ", "\t", "<C-a>" }) do
    T.eq(try({ good = bad }), { "cdp", true }, "not one printable character: " .. vim.inspect(bad))
  end
  for _, taken in ipairs({ "x", "e", "K", "u", "q", "R", "H", "L", "]", "[", "g", ".", ":", "v", "V", "0", "5" }) do
    T.eq(try({ delete = taken }), { "cdp", true }, "taken: " .. taken)
  end
  T.eq(try({ comment = "p" }), { "cdp", true }, "duplicate with a default")
  T.eq(try({ comment = "m", delete = "m", good = "a" }), { "cdp", true }, "duplicate among the three")
  local _, w = core.resolve_keys({ good = "x", comment = "d" })
  T.eq(w, 'keys.looks_good "x" clashes with x; keys.comment and keys.delete are both "d"; using the default keys', "warning text")
  local triggers = require("vimnotate").TRIGGERS
  local missing = {}
  for _, lhs in ipairs(triggers.n) do
    local k = vim.keycode(lhs):sub(1, 1)
    if #lhs > 0 and not vim.tbl_contains({ "c", "C", "d", "p" }, lhs) and lhs:match("^[!-~]") and lhs ~= "<LeftMouse>" and not select(2, core.resolve_keys({ good = k })) then
      missing[#missing + 1] = lhs
    end
  end
  T.eq(missing, {}, "every thread trigger is refused as an operator key")
  T.finish("Cancel")
end

function C.keys_warning(V)
  local core = require("vimnotate.core")
  T.eq(core.keys, { comment = "c", delete = "d", good = "p" }, "a clash falls back to the defaults")
  local wb = vim.wo[V.thread_win()].winbar
  T.ok(wb:find('⚠ keys.looks_good "x" clashes with x; using the default keys', 1, true) ~= nil, "the winbar shows the warning: " .. wb)
  T.cursor(14)
  T.keys("pp")
  T.eq(T.items()[1], { kind = "good", body = "", sent = false, lw = true, at = { 14, 14 } }, "the default key works")
  T.finish("Cancel")
end

function C.keys_empty(V)
  local core = require("vimnotate.core")
  T.eq(core.keys, { comment = "c", delete = "d", good = "p" }, "an empty key falls back to the defaults")
  T.ok(core.keys_warning ~= nil and core.keys_warning:find('keys.comment "" is not one printable ASCII character', 1, true) ~= nil, "and warns: " .. tostring(core.keys_warning))
  T.finish("Cancel")
end

function C.keys_w(V, A)
  T.cursor(2)
  T.keys("wwline<CR>")
  T.eq(shape(A, newest(A)), { "comment", "line", { 2, 2 } }, "ww comments the line when w is the comment key")
  T.finish("Cancel")
end

function C.keys_custom(V, A)
  local cases = {
    { 0, "mmone<CR>", { "comment", "one", { 0, 0 } } },
    { 1, "2Mtwo<CR>", { "comment", "two", { 1, 2 } } },
    { 3, "mwword<CR>", { "comment", "word", { 3, 0, 3, 5 } } },
    { 8, "ss", { "delete", "", { 8, 8 } } },
    { 9, "2ss", { "delete", "", { 9, 10 } } },
    { 11, "s2j", { "delete", "", { 11, 13 } } },
    { 14, "yy", { "good", "", { 14, 14 } } },
    { 15, "y3y", { "good", "", { 15, 17 } } },
    { 18, "ye", { "good", "", { 18, 0, 18, 4 } } },
    { 19, "Vjy", { "good", "", { 19, 20 } } },
    { 21, "vem<CR>", nil },
    { 21, "vemvis<CR>", { "comment", "vis", { 21, 0, 21, 4 } } },
    { 22, "VMup<CR>", { "comment", "up", { 22, 22 } } },
    { 23, "vjs", { "delete", "", { 23, 0, 24, 1 } } },
  }
  for _, c in ipairs(cases) do
    T.cursor(c[1])
    local n = vim.tbl_count(A.items)
    T.keys(c[2])
    if c[3] then
      T.eq(shape(A, newest(A)), c[3], c[2] .. " on row " .. c[1])
    else
      T.eq(vim.tbl_count(A.items), n, c[2] .. " with an empty comment adds nothing")
    end
  end
  T.cursor(25)
  T.keys("y2y")
  T.cursor(28)
  T.keys(".")
  T.eq(shape(A, newest(A)), { "good", "", { 28, 29 } }, "y2y . repeats two lines")
  for _, lhs in ipairs({ "c", "d", "p", "C" }) do
    T.eq(vim.fn.maparg(lhs, "n", false, true).buffer, nil, lhs .. " is not mapped in the thread")
  end
  local wb = vim.wo[V.thread_win()].winbar
  T.ok(wb:find("m s y {motion} comment/delete/good", 1, true) ~= nil, "the winbar names the configured keys: " .. wb)
  T.ok(not wb:find("⚠", 1, true), "no warning")
  local tr = V.TRIGGERS
  T.eq({ vim.list_slice(tr.n, 1, 4), tr.x, tr.o }, { { "m", "s", "y", "M" }, { "m", "s", "y", "M", "<LeftMouse>" }, { "m", "s", "y" } }, "triggers follow the keys")
  T.cursor(30)
  vim.api.nvim_input("V")
  vim.defer_fn(function()
    T.eq(vim.api.nvim_buf_get_lines(V.bars.action.buf, 0, -1, false)[1], " 👍 looks good (y)  💬 comment (m)  ❌ delete (s) ", "action bar names the configured keys")
    vim.api.nvim_input("<Esc>")
    vim.defer_fn(function()
      T.finish("Cancel")
    end, 30)
  end, 50)
end

function C.keys_prefix(V, A)
  local core = require("vimnotate.core")
  T.eq(core.keys, { comment = "i", delete = "d", good = "a" }, "a and i accepted")
  local cases = {
    { 0, "ae", { "good", "", { 0, 0, 0, 4 } } },
    { 1, "aaa", { "good", "", { 1, 1 } } },
    { 2, "2aaa", { "good", "", { 2, 3 } } },
    { 4, "a_", { "good", "", { 4, 4 } } },
    { 9, "aap", { "good", "", { 8, 30 } } },
    { 9, "dap", { "delete", "", { 8, 30 } } },
    { 9, "iapx<CR>", { "comment", "x", { 8, 30 } } },
    { 3, "dip", { "delete", "", { 0, 6 } } },
    { 3, "iiiline<CR>", { "comment", "line", { 3, 3 } } },
    { 5, "Ibig<CR>", { "comment", "big", { 5, 5 } } },
    { 12, "daw", { "delete", "", { 12, 0, 12, 5 } } },
    { 13, "aaf", { "good", "", { 13, 0, 13, 4 } } },
    { 14, "daf", { "delete", "", { 14, 0, 14, 4 } } },
    { 2, "vapd", { "delete", "", { 0, 7 } } },
    { 16, "vafd", { "delete", "", { 16, 0, 16, 4 } } },
  }
  for _, c in ipairs(cases) do
    T.cursor(c[1])
    T.keys(c[2])
    T.eq(shape(A, newest(A)), c[3], c[2] .. " on row " .. c[1])
  end
  T.eq(vim.fn.maparg("aa", "o", false, true).buffer, nil, "the aa line map is gone once the operator ends")
  T.cursor(20)
  T.keys("aaa")
  T.cursor(22)
  T.keys(".")
  T.eq(shape(A, newest(A)), { "good", "", { 22, 22 } }, "aaa . repeats the line")
  T.cursor(24)
  T.keys("iiirep<CR>")
  T.cursor(26)
  T.keys(".<CR>")
  T.eq(shape(A, newest(A)), { "comment", "rep", { 26, 26 } }, "iii . repeats with the last body")
  T.cursor(27)
  T.keys("a<Esc>")
  T.eq(vim.fn.maparg("aa", "o", false, true).buffer, nil, "Esc drops the aa line map")
  for _, m in ipairs({ "x", "o" }) do
    T.eq(vim.fn.maparg("af", m, false, true).buffer, 0, "global " .. m .. "-mode af survives unshadowing")
    T.eq(vim.fn.maparg("a", m, false, true).buffer, nil, "a is not mapped in " .. m .. " mode")
    T.eq(vim.fn.maparg("i", m, false, true).buffer, nil, "i is not mapped in " .. m .. " mode")
  end
  T.eq(vim.fn.maparg("ab", "n"), "", "a global normal-mode ab is unshadowed")
  T.eq({ V.TRIGGERS.x, V.TRIGGERS.o }, { { "d", "<LeftMouse>" }, { "d" } }, "no x or o triggers for text-object prefixes")
  T.cursor(29)
  vim.api.nvim_input("V")
  vim.defer_fn(function()
    local bar = V.bars.action
    T.eq(vim.api.nvim_buf_get_lines(bar.buf, 0, -1, false)[1], " 👍 looks good  💬 comment  ❌ delete (d) ", "no key shown for keys unmapped in visual mode")
    local pos = vim.api.nvim_win_get_position(bar.win)
    local x = pos[2] + bar.spans[1].from + 2
    T.mouse({ { "press", pos[1], x }, { "release", pos[1], x } }, function()
      T.eq(shape(A, newest(A)), { "good", "", { 29, 29 } }, "looks good from the action bar")
      T.finish("Cancel")
    end)
  end, 50)
end

function C.compose_box_wrap(V)
  local c, region, before
  local function grab()
    vim.cmd("redraw")
    local out = {}
    for r = region.top, region.bottom do
      local line = ""
      for col = region.left, region.right do
        line = line .. vim.fn.screenstring(r, col)
      end
      out[#out + 1] = line
    end
    return out
  end
  local steps = {
    { "cc", function()
      c = V.composing()
      local body = string.rep("abcd ", math.floor(c.width / 5)) .. string.rep("w", c.width % 5)
      vim.api.nvim_input(body .. " tail of the comment")
    end },
    { "<Esc>", function()
      local pos = vim.api.nvim_win_get_position(c.win)
      T.eq({ vim.api.nvim_win_get_config(c.win).border, c.height }, { "none", 2 }, "inline compose: borderless float, two rows")
      region = { top = pos[1] + 1, bottom = pos[1] + 2, left = pos[2] - 1, right = pos[2] + c.width + 2 }
      before = grab()
      T.eq({ vim.fn.strcharpart(before[1], 0, 2), vim.fn.strcharpart(before[1], vim.fn.strchars(before[1]) - 2) }, { "│ ", " │" }, "frame drawn around the float")
    end },
    { "<CR>", function()
      T.eq(V.composing(), nil, "saved")
      T.eq(grab(), before, "box rows match the compose rows cell for cell")
      T.eq(#T.items(), 1, "one comment")
    end },
  }
  local i = 0
  local function nxt()
    i = i + 1
    local s = steps[i]
    if not s then
      return T.finish("Cancel")
    end
    if i == 1 then
      T.cursor(1)
    end
    vim.api.nvim_input(s[1])
    vim.defer_fn(function()
      local ok, err = pcall(s[2])
      if not ok then
        T.ok(false, "step " .. i .. ": " .. tostring(err))
        return T.finish("Cancel")
      end
      vim.defer_fn(nxt, 30)
    end, 60)
  end
  vim.defer_fn(nxt, 300)
end

function C.wrap_matches_nvim()
  local wrap_text = require("vimnotate.boxes").wrap_text
  local function nvim_rows(text, width)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { text })
    local w = vim.api.nvim_open_win(b, false, { relative = "editor", row = 0, col = 0, width = width, height = 20, style = "minimal" })
    vim.wo[w].wrap = true
    vim.wo[w].linebreak = true
    vim.cmd("redraw")
    local rows = {}
    for r = 1, vim.api.nvim_win_text_height(w, {}).all do
      local l = ""
      for col = 1, width do
        l = l .. vim.fn.screenstring(r, col)
      end
      rows[#rows + 1] = l
    end
    vim.api.nvim_win_close(w, true)
    vim.api.nvim_buf_delete(b, { force = true })
    return rows
  end
  local function box_rows(text, width)
    return vim.tbl_map(function(l)
      return l .. string.rep(" ", width - vim.fn.strdisplaywidth(l))
    end, wrap_text(text, width))
  end
  local cases = {
    { "dddd ffffff end. dddd eeeee end. x,y a ffffff", 16 },
    { "bb ccc bb foo-bar foo-bar bb end. ffffff bb", 9 },
    { "   verylongwordthatexceeds bb foo-bar", 16 },
    { "- ffffff bb foo-bar a.b.c", 8 },
    { "très 日本語 x,y end. a.b.c ccc dddd", 10 },
    { "aaaa  bbbb   cccc dddd", 9 },
    { "abc\tdef xyz", 12 },
    { "a\tb\tc d", 10 },
    { "e\204\129e\204\129e\204\129 xyz", 4 },
    { "日本語日本語", 5 },
    { "", 5 },
    { "ends at the edge-", 8 },
  }
  for _, case in ipairs(cases) do
    T.eq(box_rows(case[1], case[2]), nvim_rows(case[1], case[2]), "wraps like nvim: " .. case[1] .. " @" .. case[2])
  end
  local saved = vim.go.breakat
  vim.go.breakat = " "
  T.eq(box_rows("foo-bar baz-qux zz", 9), nvim_rows("foo-bar baz-qux zz", 9), "custom breakat")
  vim.go.breakat = saved
  T.finish("Cancel")
end

function C.hint_show(V)
  local bar = V.bars.hint
  local tw = V.thread_win()
  local function text()
    if not (bar.win and vim.api.nvim_win_is_valid(bar.win)) then
      return nil
    end
    return vim.api.nvim_buf_get_lines(bar.buf, 0, -1, false)[1]
  end
  local with = " 📝 edit (e)  🧹 remove (x)  🔍 show (K) "
  local without = " 📝 edit (e)  🧹 remove (x) "
  local row
  local steps = {
    function()
      T.cursor(0)
      row = vim.fn.getwininfo(tw)[1].botline - 1
      T.add(row, "comment", "below the fold")
      T.cursor(row - 1)
      T.keys("j")
    end,
    function()
      T.eq({ V.view.mode, text(), vim.api.nvim_win_get_width(bar.win) }, { "inline", with, 41 }, "box below the window: show offered")
      vim.api.nvim_win_call(tw, function()
        vim.cmd("normal! zt")
      end)
    end,
    function()
      T.eq(text(), without, "scrolled into view: show dropped")
      V.view.setting = "off"
      V.apply_view()
    end,
    function()
      T.eq({ V.view.mode, text() }, { "off", with }, "view off: show offered")
      V.view.setting = "rail"
      V.apply_view()
    end,
    function()
      T.eq({ V.view.mode, text() }, { "rail", without }, "rail showing the bubble: show dropped")
      local pos = vim.api.nvim_win_get_position(bar.win)
      local x = pos[2] + bar.spans[#bar.spans].from + 3
      T.mouse({ { "press", pos[1], x }, { "release", pos[1], x } }, function()
        T.eq(#T.items(), 0, "the last span is remove and clicks through")
        T.finish("Cancel")
      end)
    end,
  }
  local i = 0
  local function nxt()
    i = i + 1
    if steps[i] then
      local ok, err = pcall(steps[i])
      if not ok then
        T.ok(false, "step " .. i .. ": " .. tostring(err))
        return T.finish("Cancel")
      end
      if i < #steps then
        vim.defer_fn(nxt, 400)
      end
    end
  end
  vim.defer_fn(nxt, 300)
end

function C.item_shown_edges(V)
  local tw = V.thread_win()
  local function at(top, topfill)
    vim.api.nvim_win_call(tw, function()
      vim.fn.winrestview({ topline = top + 1, topfill = topfill or 0, skipcol = 0 })
    end)
    V.apply_view()
    return vim.api.nvim_win_call(tw, vim.fn.winsaveview).topfill
  end
  local a = T.add(25, "comment", "x")
  T.cursor(0)
  vim.wait(300, function()
    return false
  end)
  T.eq(V.view.mode, "inline", "inline view")
  local h = vim.fn.getwininfo(tw)[1].height
  local top = 25 - (h - 4)
  at(top)
  T.eq(V.item_shown(a), true, "inline: bottom border on the last text row is shown")
  at(top - 1)
  T.eq(V.item_shown(a), false, "inline: bottom border one row below is not")
  T.add(top - 1, "comment", "1\n2\n3\n4\n5")
  T.eq({ at(top, 0), V.item_shown(a) }, { 0, true }, "inline: no filler above topline")
  T.eq({ at(top, 1), V.item_shown(a) }, { 1, false }, "inline: a box tail above topline counts")
  V.view.setting = "rail"
  V.apply_view()
  T.eq(V.view.mode, "rail", "rail view")
  local rh = vim.fn.getwininfo(V.view.rail_win)[1].height
  T.eq(rh, h, "rail text area matches the thread's")
  at(25 - (h - 3))
  T.eq(V.item_shown(a), true, "rail: bubble ending on the last text row is whole")
  at(25 - (h - 2))
  T.eq(V.item_shown(a), false, "rail: bubble one row lower is cut")
  T.finish("Cancel")
end

return C
