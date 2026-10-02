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
  local win = V.ensure_note()
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

return C
