local raw_path = vim.env.VIMNOTATE_RAW
local reply_path = vim.env.VIMNOTATE_REPLY
local state_path = vim.env.VIMNOTATE_STATE ~= "" and vim.env.VIMNOTATE_STATE or nil
local note_path = vim.fn.fnamemodify(reply_path, ":h") .. "/note.md"

local M = {}
package.loaded["vimnotate"] = M

local cancelled = false
local note_buf = nil
local note_win = nil

vim.o.swapfile = false
vim.o.undofile = false
vim.o.mouse = "a"
vim.o.laststatus = 0
vim.o.autowriteall = true

local f = assert(io.open(raw_path, "rb"))
local raw = f:read("*a")
f:close()

local function apply_sgr(attrs, params)
  local parts = vim.split(params:gsub(":", ";"), ";", { plain = true })
  local i = 1
  while i <= #parts do
    local n = tonumber(parts[i]) or 0
    if n == 0 then
      attrs = {}
    elseif n == 1 then
      attrs.bold = true
    elseif n == 3 then
      attrs.italic = true
    elseif n == 4 then
      attrs.underline = true
    elseif n == 22 then
      attrs.bold = nil
    elseif n == 23 then
      attrs.italic = nil
    elseif n == 24 then
      attrs.underline = nil
    elseif n >= 30 and n <= 37 then
      attrs.fg = n - 30
    elseif n == 39 then
      attrs.fg = nil
    elseif n >= 40 and n <= 47 then
      attrs.bg = n - 40
    elseif n == 49 then
      attrs.bg = nil
    elseif n >= 90 and n <= 97 then
      attrs.fg = n - 90 + 8
    elseif n >= 100 and n <= 107 then
      attrs.bg = n - 100 + 8
    elseif n == 38 or n == 48 then
      local key = n == 38 and "fg" or "bg"
      if parts[i + 1] == "2" then
        attrs[key] = string.format(
          "#%02x%02x%02x",
          tonumber(parts[i + 2]) or 0,
          tonumber(parts[i + 3]) or 0,
          tonumber(parts[i + 4]) or 0
        )
        i = i + 4
      elseif parts[i + 1] == "5" then
        attrs[key] = tonumber(parts[i + 2]) or 0
        i = i + 2
      end
    end
    i = i + 1
  end
  return attrs
end

local function color_val(c)
  if type(c) == "string" then
    return c
  end
  if type(c) == "number" and c < 16 then
    return vim.g["terminal_color_" .. c]
  end
  return nil
end

local hl_cache = {}
local function hl_for(attrs)
  if not next(attrs) then
    return nil
  end
  local key = table.concat({
    tostring(attrs.fg or ""),
    tostring(attrs.bg or ""),
    attrs.bold and "b" or "",
    attrs.italic and "i" or "",
    attrs.underline and "u" or "",
  }, "_")
  if not hl_cache[key] then
    local name = "Vimnotate" .. key:gsub("[^%w]", "x")
    vim.api.nvim_set_hl(0, name, {
      fg = color_val(attrs.fg),
      bg = color_val(attrs.bg),
      bold = attrs.bold or false,
      italic = attrs.italic or false,
      underline = attrs.underline or false,
    })
    hl_cache[key] = name
  end
  return hl_cache[key]
end

raw = raw:gsub("\27%][^\7\27]*\7", ""):gsub("\27%][^\27]*\27\\", ""):gsub("\r\n", "\n"):gsub("\r", "")
local text_lines = {}
local line_spans = {}
local attrs = {}
for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
  local out = {}
  local byte = 0
  local spans = {}
  local pos = 1
  while true do
    local s, e, params, final = line:find("\27%[([%d;:]*)(%a)", pos)
    local chunk = line:sub(pos, s and s - 1 or #line)
    chunk = chunk:gsub("[%c\27]", "")
    if #chunk > 0 then
      out[#out + 1] = chunk
      local group = hl_for(attrs)
      if group then
        spans[#spans + 1] = { byte, byte + #chunk, group }
      end
      byte = byte + #chunk
    end
    if not s then
      break
    end
    if final == "m" then
      attrs = apply_sgr(attrs, params)
    end
    pos = e + 1
  end
  text_lines[#text_lines + 1] = table.concat(out)
  line_spans[#line_spans + 1] = spans
end

local thread = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(thread)
vim.api.nvim_buf_set_lines(thread, 0, -1, false, text_lines)
local ns = vim.api.nvim_create_namespace("vimnotate")
for row, spans in ipairs(line_spans) do
  for _, sp in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(thread, ns, row - 1, sp[1], { end_col = sp[2], hl_group = sp[3] })
  end
end
vim.bo[thread].modifiable = false
M.thread = thread

local function scrub_win(win)
  if win == -1 then
    return
  end
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = false
  vim.wo[win].breakindent = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].colorcolumn = ""
  vim.wo[win].fillchars = "eob: "
  vim.wo[win].winfixbuf = vim.v.vim_did_enter == 1
end
scrub_win(vim.api.nvim_get_current_win())
vim.cmd("normal! G")
vim.cmd("clearjumps")

local function thread_win()
  return vim.fn.bufwinid(thread)
end
M.thread_win = thread_win

local function note_text()
  if note_buf and vim.api.nvim_buf_is_valid(note_buf) then
    return vim.trim(table.concat(vim.api.nvim_buf_get_lines(note_buf, 0, -1, false), "\n"))
  end
  return ""
end

local function note_shown()
  return note_win ~= nil and vim.api.nvim_win_is_valid(note_win)
end

local function warn(msg)
  vim.api.nvim_echo({ { msg, "WarningMsg" } }, false, {})
end

local KINDS = {
  comment = { glyph = "💬", label = "comment", priority = 0, hl = "VimnotateComment", mark = "VimnotateCommentMark" },
  good = { glyph = "👍", label = "looks good", priority = 1, hl = "VimnotateGood", mark = "VimnotateGoodMark" },
  delete = { glyph = "✗", label = "delete this", priority = 2, hl = "VimnotateDelete", mark = "VimnotateDeleteMark" },
}
M.KINDS = KINDS

local function define_highlights()
  vim.api.nvim_set_hl(0, "VimnotateComment", { bg = "#5f5f00", ctermbg = 58 })
  vim.api.nvim_set_hl(0, "VimnotateGood", { bg = "#005f00", ctermbg = 22 })
  vim.api.nvim_set_hl(0, "VimnotateDelete", { bg = "#5f0000", ctermbg = 52, strikethrough = true, cterm = { strikethrough = true } })
  vim.api.nvim_set_hl(0, "VimnotateCommentMark", { fg = "#afaf5f", ctermfg = 143, italic = true, cterm = { italic = true } })
  vim.api.nvim_set_hl(0, "VimnotateGoodMark", { fg = "#5faf5f", ctermfg = 71, italic = true, cterm = { italic = true } })
  vim.api.nvim_set_hl(0, "VimnotateDeleteMark", { fg = "#d75f5f", ctermfg = 167, italic = true, cterm = { italic = true } })
  vim.api.nvim_set_hl(0, "VimnotateCommentBorder", { fg = "#d7d700", ctermfg = 184 })
  vim.api.nvim_set_hl(0, "VimnotateGoodBorder", { fg = "#5fd75f", ctermfg = 77 })
  vim.api.nvim_set_hl(0, "VimnotateDeleteBorder", { fg = "#ff5f5f", ctermfg = 203 })
  vim.api.nvim_set_hl(0, "VimnotateTitle", { link = "Comment" })
  vim.api.nvim_set_hl(0, "VimnotateBar", { fg = "#d0d0d0", bg = "#444444", ctermfg = 252, ctermbg = 238 })
  for _, name in ipairs({ "Comment", "Good", "Delete" }) do
    local accent = vim.api.nvim_get_hl(0, { name = "Vimnotate" .. name .. "Border" })
    local base = { fg = accent.fg, ctermfg = accent.ctermfg, bg = "#444444", ctermbg = 238 }
    vim.api.nvim_set_hl(0, "VimnotateHint" .. name, base)
    vim.api.nvim_set_hl(0, "VimnotateBar" .. name, vim.tbl_extend("force", base, { bold = true, cterm = { bold = true } }))
    vim.api.nvim_set_hl(0, "Vimnotate" .. name .. "BorderBold", { fg = accent.fg, ctermfg = accent.ctermfg, bold = true, cterm = { bold = true } })
  end
  vim.api.nvim_set_hl(0, "VimnotateCommentActive", { bg = "#878700", ctermbg = 100 })
  vim.api.nvim_set_hl(0, "VimnotateGoodActive", { bg = "#008700", ctermbg = 28 })
  vim.api.nvim_set_hl(0, "VimnotateDeleteActive", { bg = "#870000", ctermbg = 88, strikethrough = true, cterm = { strikethrough = true } })
  vim.api.nvim_set_hl(0, "VimnotateCommentSent", { bg = "#3a3a1c", ctermbg = 237 })
  vim.api.nvim_set_hl(0, "VimnotateGoodSent", { bg = "#1c3a1c", ctermbg = 237 })
  vim.api.nvim_set_hl(0, "VimnotateDeleteSent", { bg = "#3a1c1c", ctermbg = 237, strikethrough = true, cterm = { strikethrough = true } })
  vim.api.nvim_set_hl(0, "VimnotateSentMark", { fg = "#6c6c6c", ctermfg = 242, italic = true, cterm = { italic = true } })
  for name, dim in pairs({ Comment = { "#87875f", 101 }, Good = { "#5f875f", 65 }, Delete = { "#875f5f", 95 } }) do
    vim.api.nvim_set_hl(0, "Vimnotate" .. name .. "BorderSent", { fg = dim[1], ctermfg = dim[2] })
    vim.api.nvim_set_hl(0, "Vimnotate" .. name .. "BorderSentBold", { fg = dim[1], ctermfg = dim[2], bold = true, cterm = { bold = true } })
  end
  vim.api.nvim_set_hl(0, "VimnotateEdge", { fg = "#626262", ctermfg = 241 })
  vim.api.nvim_set_hl(0, "VimnotateLabel", { fg = "#8a8a8a", ctermfg = 245, italic = true, cterm = { italic = true } })
  vim.api.nvim_set_hl(0, "VimnotateWinbarNote", { fg = "#d7d700", ctermfg = 184, bold = true, cterm = { bold = true } })
end
define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { callback = define_highlights })

local A = { items = {}, listeners = {} }
M.annotations = A
local range_ns = vim.api.nvim_create_namespace("vimnotate.ranges")
local mark_ns = vim.api.nvim_create_namespace("vimnotate.marks")
A.range_ns = range_ns
A.mark_ns = mark_ns

local view = { mode = "off", bubbles = {} }
M.view = view

local seq = 0
math.randomseed(os.time() + vim.fn.getpid())
local ID_CHARS = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
local function new_id()
  local t = {}
  for i = 1, 10 do
    local k = math.random(#ID_CHARS)
    t[i] = ID_CHARS:sub(k, k)
  end
  return "anno_" .. table.concat(t)
end

function A.short_id(id)
  return id:sub(-5)
end

local function line_len(row)
  return #(vim.api.nvim_buf_get_lines(thread, row, row + 1, false)[1] or "")
end

local function place(item, r)
  local kind = KINDS[item.kind]
  local opts = {
    end_row = r.erow,
    end_col = r.linewise and line_len(r.erow) or r.ecol,
    hl_group = item.sent and (kind.hl .. "Sent") or kind.hl,
    hl_eol = r.linewise or nil,
    priority = 4200 + kind.priority,
    right_gravity = false,
    end_right_gravity = true,
  }
  if item.mark then
    opts.id = item.mark
  end
  item.mark = vim.api.nvim_buf_set_extmark(thread, range_ns, r.srow, r.linewise and 0 or r.scol, opts)
  local tag = {
    virt_text = { { " " .. kind.glyph .. " " .. A.short_id(item.id) .. (item.sent and " · sent" or ""), item.sent and "VimnotateSentMark" or kind.mark } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  }
  if item.tag then
    tag.id = item.tag
  end
  item.tag = vim.api.nvim_buf_set_extmark(thread, mark_ns, r.erow, 0, tag)
end

local function emit(event, item)
  for _, fn in ipairs(A.listeners) do
    local ok, err = pcall(fn, event, item)
    if not ok then
      warn("vimnotate listener: " .. tostring(err))
    end
  end
end

function A.on_change(fn)
  table.insert(A.listeners, fn)
  return function()
    for i, g in ipairs(A.listeners) do
      if g == fn then
        table.remove(A.listeners, i)
        return
      end
    end
  end
end

function A.range(item)
  local m = vim.api.nvim_buf_get_extmark_by_id(thread, range_ns, item.mark, { details = true })
  return { srow = m[1], scol = m[2], erow = m[3].end_row, ecol = m[3].end_col, linewise = item.linewise }
end

function A.text(item)
  local r = A.range(item)
  local lines
  if r.linewise then
    lines = vim.api.nvim_buf_get_lines(thread, r.srow, r.erow + 1, false)
  else
    lines = vim.api.nvim_buf_get_text(thread, r.srow, r.scol, r.erow, r.ecol, {})
  end
  for i, l in ipairs(lines) do
    lines[i] = l:gsub("%s+$", "")
  end
  return lines
end

local H = { undo = {}, redo = {}, step = nil, muted = false }
M.history = H

vim.on_key(function()
  H.step = nil
end, vim.api.nvim_create_namespace("vimnotate.history"))

local function snapshot(item)
  local r = A.range(item)
  return {
    id = item.id,
    kind = item.kind,
    linewise = item.linewise,
    body = item.body,
    seq = item.seq,
    sent = item.sent,
    srow = r.srow,
    scol = r.scol,
    erow = r.erow,
    ecol = r.ecol,
  }
end

local function record(op)
  if H.muted then
    return
  end
  if not H.step then
    H.step = {}
    H.undo[#H.undo + 1] = H.step
    H.redo = {}
  end
  table.insert(H.step, op)
end

local function revive(s)
  local item = { id = s.id, kind = s.kind, linewise = s.linewise, body = s.body, seq = s.seq, sent = s.sent }
  place(item, s)
  A.items[item.id] = item
  emit("add", item)
  return item
end

function A.add(spec)
  seq = seq + 1
  local item = { id = new_id(), kind = spec.kind, linewise = spec.linewise or false, body = spec.body or "", seq = seq, sent = spec.sent }
  place(item, spec)
  A.items[item.id] = item
  record({ op = "add", snap = snapshot(item) })
  emit("add", item)
  return item
end

function A.get(id)
  return A.items[id]
end

function A.update(id, fields)
  local item = A.items[id]
  if not item then
    return nil
  end
  local old = { body = item.body, kind = item.kind, sent = item.sent or false }
  if fields.body ~= nil then
    item.body = fields.body
  end
  if fields.kind then
    item.kind = fields.kind
  end
  if fields.sent ~= nil then
    item.sent = fields.sent
  elseif item.body ~= old.body or item.kind ~= old.kind then
    item.sent = false
  end
  local new = { body = item.body, kind = item.kind, sent = item.sent or false }
  if new.kind ~= old.kind or new.sent ~= old.sent then
    place(item, A.range(item))
  end
  if not vim.deep_equal(old, new) then
    record({ op = "update", id = id, before = old, after = new })
  end
  emit("update", item)
  return item
end

function A.remove(id)
  local item = A.items[id]
  if not item then
    return nil
  end
  record({ op = "remove", snap = snapshot(item) })
  vim.api.nvim_buf_del_extmark(thread, range_ns, item.mark)
  vim.api.nvim_buf_del_extmark(thread, mark_ns, item.tag)
  A.items[id] = nil
  emit("remove", item)
  return item
end

local function before(a, b)
  if a.srow ~= b.srow then
    return a.srow < b.srow
  end
  return a.scol < b.scol
end

function A.list()
  local out = {}
  for _, item in pairs(A.items) do
    out[#out + 1] = { item = item, r = A.range(item) }
  end
  table.sort(out, function(x, y)
    if x.r.srow ~= y.r.srow or x.r.scol ~= y.r.scol then
      return before(x.r, y.r)
    end
    return x.item.seq < y.item.seq
  end)
  local items = {}
  for i, e in ipairs(out) do
    items[i] = e.item
  end
  return items
end

function A.at(row, col)
  local hits = {}
  for _, item in pairs(A.items) do
    local r = A.range(item)
    local inside
    if r.linewise then
      inside = row >= r.srow and row <= r.erow
    else
      inside = (row > r.srow or (row == r.srow and col >= r.scol)) and (row < r.erow or (row == r.erow and col < r.ecol))
    end
    if inside then
      hits[#hits + 1] = { item = item, size = (r.erow - r.srow) * 100000 + (r.linewise and 99999 or (r.ecol - r.scol)) }
    end
  end
  table.sort(hits, function(x, y)
    if x.size ~= y.size then
      return x.size < y.size
    end
    return x.item.seq > y.item.seq
  end)
  local items = {}
  for i, h in ipairs(hits) do
    items[i] = h.item
  end
  return items
end

function A.at_cursor(win)
  win = win or thread_win()
  if win == -1 then
    return nil
  end
  local cur = vim.api.nvim_win_get_cursor(win)
  return A.at(cur[1] - 1, cur[2])[1]
end

local function single_line(text)
  return vim.trim(text:gsub("%s+", " "))
end

function A.describe(item)
  local kind = KINDS[item.kind]
  local body = vim.trim(item.body)
  local detail = body ~= "" and single_line(body) or ('"' .. vim.fn.strcharpart(single_line(table.concat(A.text(item), " ")), 0, 60) .. '"')
  return kind.glyph .. " " .. A.short_id(item.id) .. " " .. kind.label .. (item.sent and " (sent)" or "") .. ": " .. detail
end

local VERBS = { add = "added", remove = "removed", update = "edited" }

local function replay(dir)
  local from, to = dir < 0 and H.undo or H.redo, dir < 0 and H.redo or H.undo
  local step = table.remove(from)
  if not step then
    M.flash(dir < 0 and "nothing to undo" or "nothing to redo")
    return false
  end
  H.muted = true
  local touched
  local ok, err = pcall(function()
    local first, last, inc = 1, #step, 1
    if dir < 0 then
      first, last, inc = #step, 1, -1
    end
    for i = first, last, inc do
      local o = step[i]
      local id = o.snap and o.snap.id or o.id
      local add = (o.op == "add") == (dir > 0)
      if o.op == "update" then
        A.update(id, dir < 0 and o.before or o.after)
      elseif add then
        revive(o.snap)
      else
        A.remove(id)
      end
      touched = touched or A.items[id] or o.snap
    end
  end)
  H.muted = false
  H.step = nil
  to[#to + 1] = step
  if not ok then
    warn("vimnotate history: " .. tostring(err))
    return false
  end
  local o = step[1]
  local id = o.snap and o.snap.id or o.id
  local kind = KINDS[(touched and touched.kind) or "comment"]
  local msg = (dir < 0 and "undid: " or "redid: ") .. VERBS[o.op] .. " " .. kind.label .. " " .. A.short_id(id)
  if #step > 1 then
    msg = msg .. " (+" .. (#step - 1) .. ")"
  end
  local tw = vim.fn.bufwinid(thread)
  if touched and tw ~= -1 then
    local r = touched.srow and touched or A.range(touched)
    vim.api.nvim_win_set_cursor(tw, { r.srow + 1, r.linewise and 0 or r.scol })
  end
  M.flash(msg)
  return true
end

function M.undo(count)
  for _ = 1, count or vim.v.count1 do
    if not replay(-1) then
      return
    end
  end
end

function M.redo(count)
  for _ = 1, count or vim.v.count1 do
    if not replay(1) then
      return
    end
  end
end

local function refresh_loclist()
  local tw = thread_win()
  if tw == -1 then
    return
  end
  local items = {}
  for _, item in ipairs(A.list()) do
    local r = A.range(item)
    items[#items + 1] = {
      bufnr = thread,
      lnum = r.srow + 1,
      col = r.linewise and 1 or r.scol + 1,
      end_lnum = r.erow + 1,
      end_col = r.linewise and 0 or r.ecol + 1,
      text = A.describe(item),
    }
  end
  vim.fn.setloclist(tw, {}, "r", { title = "vimnotate annotations", items = items })
end

local HINTS = "c d p {motion} comment/delete/good · u undo · ]a [a · K show · e edit · x drop · R toggle view · Tab note · q send"

local function thread_winbar()
  local counts, sent = {}, 0
  for _, item in pairs(A.items) do
    if item.sent then
      sent = sent + 1
    else
      counts[item.kind] = (counts[item.kind] or 0) + 1
    end
  end
  local tally = {}
  for _, k in ipairs({ "comment", "delete", "good" }) do
    if counts[k] then
      tally[#tally + 1] = KINDS[k].glyph .. counts[k]
    end
  end
  if sent > 0 then
    tally[#tally + 1] = sent .. " sent"
  end
  if note_text() ~= "" then
    tally[#tally + 1] = "%@v:lua.vimnotate_note_click@%#VimnotateWinbarNote#✎ note%*%T"
  end
  local head = #tally > 0 and ("THREAD " .. table.concat(tally, " ")) or "THREAD"
  if view.flash then
    head = head .. " · " .. view.flash
  end
  return head .. " · %<" .. HINTS
end

local function refresh_winbar()
  local tw = thread_win()
  if tw ~= -1 then
    vim.wo[tw].winbar = thread_winbar()
  end
end

A.on_change(function()
  refresh_loclist()
  refresh_winbar()
end)

local function hide_chrome()
  vim.o.mouse = "a"
  for _, lhs in ipairs({ "<LeftMouse>", "<LeftDrag>", "<LeftRelease>", "<2-LeftMouse>", "<3-LeftMouse>", "<4-LeftMouse>" }) do
    pcall(vim.keymap.del, { "n", "i", "v", "x" }, lhs)
  end
  pcall(function()
    require("lualine").hide()
  end)
  vim.o.laststatus = 0
end

vim.api.nvim_create_autocmd("OptionSet", {
  pattern = "laststatus",
  callback = function()
    if vim.o.laststatus ~= 0 then
      vim.schedule(function()
        vim.o.laststatus = 0
      end)
    end
  end,
})

local markdown_warm = false
local function prewarm_markdown()
  if markdown_warm then
    return
  end
  markdown_warm = true
  local buf = vim.fn.bufadd(vim.fn.fnamemodify(reply_path, ":h") .. "/.warmup.md")
  vim.fn.bufload(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.bo[buf].filetype = "markdown"
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
end

local function unshadow(maps, mode, lhs)
  local prefix = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  local umbrella = mode == "x" and "v" or mode
  for _, m in ipairs(maps) do
    local applies = m.buffer == 0
      and (m.mode == " " or m.mode:find(mode, 1, true) or m.mode:find(umbrella, 1, true))
    if applies then
      local other = m.lhsraw or vim.api.nvim_replace_termcodes(m.lhs, true, false, true)
      if #other > #prefix and other:sub(1, #prefix) == prefix then
        pcall(vim.keymap.del, mode, m.lhs)
      end
    end
  end
end

M.BUFFER_SWITCHERS = { "]b", "[b", "]B", "[B", "]A", "[A", "<Space><Space>", "<C-^>", "<C-6>", "gf", "gF" }

local TRIGGERS = {
  n = { "c", "C", "d", "p", "x", "e", "K", "u", "<C-r>", "<C-o>", "<C-i>", "]a", "[a", "q", "R", "H", "L", "<Tab>", "<S-Tab>", "<LeftMouse>" },
  x = { "c", "C", "d", "p", "<LeftMouse>" },
  o = { "c", "d", "p" },
}
M.TRIGGERS = TRIGGERS

local function unshadow_triggers()
  local maps = vim.fn.maplist()
  for mode, keys in pairs(TRIGGERS) do
    for _, lhs in ipairs(keys) do
      unshadow(maps, mode, lhs)
    end
  end
end
M.unshadow_triggers = unshadow_triggers
local unshadow_queued = false
vim.api.nvim_create_autocmd("User", {
  pattern = "LazyLoad",
  callback = function()
    if unshadow_queued then
      return
    end
    unshadow_queued = true
    vim.schedule(function()
      unshadow_queued = false
      unshadow_triggers()
    end)
  end,
})

local pending_ns = vim.api.nvim_create_namespace("vimnotate.pending")
local COMPOSE_MIN_WIDTH = 48
local COMPOSE_MAX_ROWS = 8
local compose = nil

local function compose_title(c, insert)
  local verb = (c.item and c.item.kind == c.kind) and "edit" or "comment"
  if insert == nil then
    insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
  end
  if insert then
    return " " .. verb .. " · enter saves · ctrl-j new line · esc normal "
  end
  return " " .. verb .. " · enter saves · q cancels · i insert "
end

local function compose_body(c)
  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(c.buf, 0, -1, false), "\n"))
end

function M.composing()
  return compose
end

local BAR_ACTIONS = {
  { kind = "good", label = "looks good", key = "p" },
  { kind = "comment", label = "comment", key = "c" },
  { kind = "delete", label = "delete", key = "d" },
}
local HINT_DELAY = 120
local bar_ns = vim.api.nvim_create_namespace("vimnotate.bar")
local bars = { action = {}, hint = {} }
M.bars = bars

local LEFT_PRESS = vim.keycode("<LeftMouse>")
local LEFT_DRAG = vim.keycode("<LeftDrag>")
local LEFT_RELEASE = vim.keycode("<LeftRelease>")
local by_mouse = false
local selection_by_mouse = false
local swallow = false
local pending_click = nil

vim.on_key(function(_, typed)
  if not typed or typed == "" then
    return
  end
  local base = typed:sub(-3)
  local left = base == LEFT_PRESS or base == LEFT_DRAG or base == LEFT_RELEASE
  if swallow then
    if base == LEFT_DRAG then
      return ""
    end
    swallow = false
    if base == LEFT_RELEASE then
      return ""
    end
  end
  by_mouse = left
end, vim.api.nvim_create_namespace("vimnotate.mouse"))

local function bar_setting()
  local v = vim.g.vimnotate_action_bar
  if v == "always" or v == "never" then
    return v
  end
  return "mouse"
end

local function bar_allowed(mouse)
  local s = bar_setting()
  return s == "always" or (s == "mouse" and mouse)
end

local function bar_visible(bar)
  return bar.win ~= nil and vim.api.nvim_win_is_valid(bar.win)
end

local function bar_hide(bar)
  if bar_visible(bar) then
    vim.api.nvim_win_close(bar.win, true)
  end
  bar.win = nil
end

local function bar_render(bar, pieces)
  if not (bar.buf and vim.api.nvim_buf_is_valid(bar.buf)) then
    bar.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[bar.buf].bufhidden = "hide"
  end
  local text, spans, col = "", {}, 0
  for _, p in ipairs(pieces) do
    local w = vim.fn.strdisplaywidth(p.text)
    spans[#spans + 1] = { from = col, to = col + w, sbyte = #text, ebyte = #text + #p.text, hl = p.hl, run = p.run }
    text = text .. p.text
    col = col + w
  end
  vim.api.nvim_buf_set_lines(bar.buf, 0, -1, false, { text })
  vim.api.nvim_buf_clear_namespace(bar.buf, bar_ns, 0, -1)
  for _, s in ipairs(spans) do
    if s.hl then
      vim.api.nvim_buf_set_extmark(bar.buf, bar_ns, 0, s.sbyte, { end_col = s.ebyte, hl_group = s.hl })
    end
  end
  bar.spans = spans
  bar.width = col
end

local function bar_config(tw, r, width)
  local info = vim.fn.getwininfo(tw)[1]
  local top = info.winrow + (info.winbar or 0)
  local bottom = top + info.height - 1
  width = math.max(1, math.min(width, info.width))
  local scol = r.linewise and 0 or r.scol
  local sp = vim.fn.screenpos(tw, r.srow + 1, scol + 1)
  local ecol = r.linewise and math.max(line_len(r.erow) - 1, 0) or math.max(r.ecol - 1, 0)
  local ep = vim.fn.screenpos(tw, r.erow + 1, ecol + 1)
  local x = r.screen_x or (sp.col > 0 and sp.col) or info.wincol
  x = math.max(0, math.min(x - info.wincol, info.width - width))
  local cfg = { width = width, height = 1, focusable = false, mouse = false, zindex = 150, border = "none" }
  if sp.row > top then
    local lp = vim.fn.screenpos(tw, r.srow + 1, 1)
    cfg.relative, cfg.win, cfg.bufpos, cfg.anchor = "win", tw, { r.srow, 0 }, "SW"
    cfg.row = lp.row > 0 and sp.row - lp.row or 0
    cfg.col = x
  elseif ep.row > 0 and ep.row < bottom then
    local lp = vim.fn.screenpos(tw, r.erow + 1, 1)
    cfg.relative, cfg.win, cfg.bufpos, cfg.anchor = "win", tw, { r.erow, 0 }, "NW"
    cfg.row = lp.row > 0 and ep.row - lp.row + 1 or 1
    cfg.col = x
  else
    cfg.relative, cfg.anchor, cfg.row, cfg.col = "editor", "NW", info.winrow - 1, info.wincol - 1 + x
  end
  return cfg
end
M.bar_config = bar_config

local function bar_show(bar, r)
  local tw = thread_win()
  if tw == -1 then
    return bar_hide(bar)
  end
  local cfg = bar_config(tw, r, bar.width)
  if bar_visible(bar) and bar.relative ~= cfg.relative then
    bar_hide(bar)
  end
  if bar_visible(bar) then
    vim.api.nvim_win_set_config(bar.win, cfg)
  else
    bar.win = vim.api.nvim_open_win(bar.buf, false, vim.tbl_extend("force", cfg, { style = "minimal", noautocmd = true }))
    vim.wo[bar.win].winhighlight = "Normal:VimnotateBar,NormalFloat:VimnotateBar"
    vim.wo[bar.win].wrap = false
  end
  bar.relative = cfg.relative
end

local function visual_range()
  local tw = thread_win()
  local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
  local v, c = vim.fn.getpos("v"), vim.fn.getpos(".")
  local a, b = { v[2] - 1, v[3] - 1 }, { c[2] - 1, c[3] - 1 }
  if a[1] > b[1] or (a[1] == b[1] and a[2] > b[2]) then
    a, b = b, a
  end
  local r = {
    srow = a[1],
    scol = math.min(a[2], line_len(a[1])),
    erow = b[1],
    ecol = math.min(b[2] + 1, line_len(b[1])),
    linewise = mode == "V",
  }
  if mode == "\22" then
    local p1, p2 = vim.fn.screenpos(tw, v[2], v[3]), vim.fn.screenpos(tw, c[2], c[3])
    if p1.col > 0 and p2.col > 0 then
      r.screen_x = math.min(p1.col, p2.col)
    end
  end
  return r
end
M.visual_range = visual_range

local function in_thread()
  local tw = thread_win()
  return tw ~= -1 and vim.api.nvim_get_current_win() == tw
end

local function action_pieces()
  local pieces = {}
  for _, a in ipairs(BAR_ACTIONS) do
    local kind = KINDS[a.kind]
    pieces[#pieces + 1] = {
      text = " " .. kind.glyph .. " " .. a.label .. " (" .. a.key .. ") ",
      hl = "VimnotateBar" .. kind.hl:sub(10),
      run = function()
        vim.api.nvim_feedkeys(a.key, "m", false)
      end,
    }
  end
  return pieces
end

local function action_update()
  local visual = vim.api.nvim_get_mode().mode:find("^[vV\22]") ~= nil
  if not (visual and in_thread() and bar_allowed(selection_by_mouse)) then
    return bar_hide(bars.action)
  end
  if not bars.action.spans then
    bar_render(bars.action, action_pieces())
  end
  bar_show(bars.action, visual_range())
end

local hint_item = nil
local hint_token = 0

local function hint_hide()
  hint_token = hint_token + 1
  hint_item = nil
  bar_hide(bars.hint)
end

local function hint_render(item)
  local name = KINDS[item.kind].hl:sub(10)
  local pieces = {}
  for i, h in ipairs({ { "e", "edit", M.edit }, { "x", "remove", M.remove_at_cursor }, { "K", "show", M.hover } }) do
    if i > 1 then
      pieces[#pieces + 1] = { text = "·", hl = "VimnotateHint" .. name }
    end
    pieces[#pieces + 1] = { text = " " .. h[1], hl = "VimnotateBar" .. name, run = h[3] }
    pieces[#pieces + 1] = { text = " " .. h[2] .. " ", hl = "VimnotateHint" .. name, run = h[3] }
  end
  bar_render(bars.hint, pieces)
  bar_show(bars.hint, A.range(item))
  hint_item = item
end

local function hint_eligible()
  return in_thread() and vim.api.nvim_get_mode().mode == "n"
end

local function hint_schedule(mouse)
  hint_token = hint_token + 1
  local token = hint_token
  vim.defer_fn(function()
    if token ~= hint_token or not hint_eligible() or not bar_allowed(mouse) then
      return
    end
    local item = A.at_cursor()
    if item then
      hint_render(item)
    end
  end, HINT_DELAY)
end

local function hint_cursor_moved()
  local item = hint_eligible() and A.at_cursor() or nil
  if item and item == hint_item and bar_visible(bars.hint) then
    return
  end
  local mouse = by_mouse
  hint_hide()
  if item then
    hint_schedule(mouse)
  end
end

local function bars_hide()
  bar_hide(bars.action)
  hint_hide()
end
M.bars_hide = bars_hide

local function bars_refresh()
  if bar_visible(bars.action) then
    action_update()
  end
  if hint_item and bar_visible(bars.hint) then
    if A.items[hint_item.id] then
      bar_show(bars.hint, A.range(hint_item))
    else
      hint_hide()
    end
  end
end

function M.bar_click()
  local run = pending_click
  pending_click = nil
  if run then
    run()
  end
end

local function bar_hit(bar)
  if not bar_visible(bar) then
    return nil
  end
  local m = vim.fn.getmousepos()
  local pos = vim.api.nvim_win_get_position(bar.win)
  local x = m.screencol - 1 - pos[2]
  if m.screenrow - 1 ~= pos[1] or x < 0 or x >= vim.api.nvim_win_get_width(bar.win) then
    return nil
  end
  for _, s in ipairs(bar.spans) do
    if s.run and x >= s.from and x < s.to then
      return s.run
    end
  end
  return function() end
end

local function click(bar)
  return function()
    local m = vim.fn.getmousepos()
    if view.rail_win and m.winid == view.rail_win and vim.api.nvim_win_is_valid(view.rail_win) then
      pending_click = function()
        M.rail_click(m.line)
      end
      swallow = true
      return "<Cmd>lua require('vimnotate').bar_click()<CR>"
    end
    local run = bar_hit(bar)
    if not run then
      return "<LeftMouse>"
    end
    pending_click = run
    swallow = true
    return "<Cmd>lua require('vimnotate').bar_click()<CR>"
  end
end

vim.keymap.set("x", "<LeftMouse>", click(bars.action), { buffer = thread, expr = true })
vim.keymap.set("n", "<LeftMouse>", click(bars.hint), { buffer = thread, expr = true })

local bar_group = vim.api.nvim_create_augroup("vimnotate.bars", { clear = true })
vim.api.nvim_create_autocmd("ModeChanged", {
  group = bar_group,
  callback = function()
    local old, new = vim.v.event.old_mode or "", vim.v.event.new_mode or ""
    local visual = new:find("^[vV\22]") ~= nil
    if visual and not old:find("^[vV\22]") then
      selection_by_mouse = by_mouse
    end
    hint_hide()
    if visual then
      vim.schedule(action_update)
    else
      bar_hide(bars.action)
      if new == "n" then
        hint_schedule(by_mouse)
      end
    end
  end,
})
vim.api.nvim_create_autocmd("CursorMoved", {
  group = bar_group,
  buffer = thread,
  callback = function()
    if vim.api.nvim_get_mode().mode:find("^[vV\22]") then
      action_update()
    else
      hint_cursor_moved()
    end
  end,
})
vim.api.nvim_create_autocmd("WinLeave", { group = bar_group, buffer = thread, callback = bars_hide })
vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "VimResized" }, {
  group = bar_group,
  callback = function()
    vim.schedule(bars_refresh)
  end,
})
A.on_change(function()
  if hint_item then
    hint_hide()
    hint_schedule(true)
  end
end)

local function compose_resize(c)
  if not vim.api.nvim_win_is_valid(c.win) then
    return
  end
  local h = vim.api.nvim_win_text_height(c.win, {}).all
  c.height = math.max(1, math.min(h, COMPOSE_MAX_ROWS))
  local cfg = M.compose_layout(c)
  cfg.title = compose_title(c)
  cfg.title_pos = "left"
  if not vim.deep_equal(cfg, c.cfg) then
    c.cfg = cfg
    vim.api.nvim_win_set_config(c.win, cfg)
  end
end

local function compose_finish(save)
  local c = compose
  if not c then
    return
  end
  compose = nil
  vim.api.nvim_buf_clear_namespace(thread, pending_ns, 0, -1)
  local body = vim.api.nvim_buf_is_valid(c.buf) and compose_body(c) or ""
  if save then
    if c.item then
      if A.items[c.item.id] then
        if c.kind ~= c.item.kind then
          if body ~= "" or c.kind ~= "comment" then
            A.update(c.item.id, { body = body, kind = c.kind })
          end
        elseif body == "" and c.kind == "comment" then
          A.remove(c.item.id)
        else
          A.update(c.item.id, { body = body })
        end
      end
    elseif body ~= "" then
      local spec = vim.deepcopy(c.range)
      spec.kind = "comment"
      spec.body = body
      A.add(spec)
      M.last_body = body
    end
  end
  M.apply_view()
  if vim.api.nvim_win_is_valid(c.win) then
    vim.api.nvim_win_close(c.win, true)
  end
  local tw = thread_win()
  if tw ~= -1 then
    vim.api.nvim_set_current_win(tw)
    M.restore_repeat()
  end
  unshadow_triggers()
end

function M.compose_save()
  compose_finish(true)
end

function M.compose_cancel()
  compose_finish(false)
end

function M.compose(opts)
  if compose then
    compose_finish(true)
  end
  bars_hide()
  local item = opts.item
  local r = item and A.range(item) or opts.range
  local c = { item = item, range = r, height = 1, kind = opts.kind or (item and item.kind) or "comment" }
  local accent = KINDS[c.kind]
  c.inline = (item and view.mode or M.planned(thread_win())) == "inline"
  local whole = r.linewise and r.erow + 1 < vim.api.nvim_buf_line_count(thread)
  vim.api.nvim_buf_set_extmark(thread, pending_ns, r.srow, r.linewise and 0 or r.scol, {
    end_row = whole and r.erow + 1 or r.erow,
    end_col = whole and 0 or (r.linewise and line_len(r.erow) or r.ecol),
    hl_group = accent.hl .. "Active",
    hl_eol = r.linewise or nil,
    priority = 4300,
  })
  c.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[c.buf].bufhidden = "wipe"
  local body = opts.body or (item and item.body) or ""
  vim.api.nvim_buf_set_lines(c.buf, 0, -1, false, vim.split(body, "\n", { plain = true }))
  compose = c
  local title = compose_title(c, true)
  c.base_width = math.max(COMPOSE_MIN_WIDTH, vim.fn.strdisplaywidth(title) + 2, vim.fn.strdisplaywidth(compose_title(c, false)) + 2)
  local cfg = M.compose_layout(c)
  cfg.border = "rounded"
  cfg.style = "minimal"
  cfg.title = title
  cfg.title_pos = "left"
  c.win = vim.api.nvim_open_win(c.buf, true, cfg)
  vim.wo[c.win].conceallevel = 2
  markdown_warm = true
  vim.bo[c.buf].filetype = "markdown"
  vim.wo[c.win].wrap = true
  vim.wo[c.win].linebreak = c.inline
  vim.wo[c.win].winfixbuf = false
  vim.wo[c.win].winhighlight = "FloatBorder:" .. accent.hl .. "Border,FloatTitle:VimnotateTitle"
  local o = { buffer = c.buf, nowait = true }
  vim.keymap.set("i", "<CR>", "<Esc><Cmd>lua require('vimnotate').compose_save()<CR>", o)
  vim.keymap.set("i", "<C-j>", "<CR>", o)
  vim.keymap.set("i", "<S-CR>", "<CR>", o)
  vim.keymap.set("i", "<M-CR>", "<CR>", o)
  vim.keymap.set("n", "<CR>", M.compose_save, o)
  vim.keymap.set("n", "q", M.compose_cancel, o)
  local group = vim.api.nvim_create_augroup("vimnotate.compose", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "WinResized" }, {
    group = group,
    callback = function()
      if compose == c then
        compose_resize(c)
      end
    end,
  })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function()
      if compose == c and vim.api.nvim_win_is_valid(c.win) then
        vim.api.nvim_win_set_config(c.win, { title = compose_title(c), title_pos = "left" })
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufWipeout" }, {
    group = group,
    buffer = c.buf,
    callback = function()
      vim.schedule(function()
        if compose == c then
          compose_finish(true)
        end
      end)
    end,
  })
  local last = vim.api.nvim_buf_line_count(c.buf)
  vim.api.nvim_win_set_cursor(c.win, { last, 0 })
  compose_resize(c)
  vim.cmd("startinsert!")
  return c
end

local function op_range(type)
  local s = vim.api.nvim_buf_get_mark(thread, "[")
  local e = vim.api.nvim_buf_get_mark(thread, "]")
  local r = { srow = s[1] - 1, scol = s[2], erow = e[1] - 1 }
  if type == "line" then
    r.linewise = true
    r.scol = 0
    r.ecol = line_len(r.erow)
    return r
  end
  local line = vim.api.nvim_buf_get_lines(thread, r.erow, r.erow + 1, false)[1] or ""
  if e[2] < #line then
    r.ecol = e[2] + vim.str_utf_end(line, e[2] + 1) + 1
  else
    r.ecol = #line
  end
  r.scol = math.min(r.scol, line_len(r.srow))
  r.linewise = false
  if r.srow == r.erow and r.ecol <= r.scol then
    r.linewise = true
    r.scol = 0
    r.ecol = line_len(r.erow)
  end
  return r
end

local OPFUNCS = { comment = "op_comment", good = "op_good", delete = "op_delete" }
local fresh = false
local replaying = false
local recording = nil
local recorder = vim.api.nvim_create_namespace("vimnotate.recorder")

local function shape_keys(r)
  if r.linewise then
    return "g@" .. (r.erow > r.srow and (r.erow - r.srow) .. "j" or "_")
  end
  local last = vim.api.nvim_buf_get_lines(thread, r.erow, r.erow + 1, false)[1] or ""
  if r.erow == r.srow then
    local n = vim.fn.strchars(last:sub(r.scol + 1, r.ecol))
    return "v" .. (n > 1 and (n - 1) .. "l" or "") .. "g@"
  end
  local n = vim.fn.strchars(last:sub(1, r.ecol))
  return "v" .. (r.erow - r.srow) .. "j0" .. (n > 1 and (n - 1) .. "l" or "") .. "g@"
end

function M.restore_repeat()
  local op = M.last_op
  local tw = thread_win()
  if not op or tw == -1 then
    return
  end
  vim.api.nvim_win_call(tw, function()
    local cur = vim.api.nvim_win_get_cursor(tw)
    vim.o.operatorfunc = "v:lua.require'vimnotate'." .. op.func
    replaying = true
    pcall(vim.cmd.normal, { op.keys, bang = op.bang })
    replaying = false
    vim.api.nvim_win_set_cursor(tw, cur)
  end)
end

local function apply_op(kind, type)
  vim.on_key(nil, recorder)
  if replaying then
    return
  end
  local r = op_range(type)
  local was_fresh = fresh
  fresh = false
  if recording then
    local motion = table.concat(recording.keys)
    local recorded = not recording.visual and motion ~= ""
    local keys = recorded and ((recording.count > 0 and recording.count or "") .. "g@" .. motion) or shape_keys(r)
    M.last_op = { kind = kind, func = OPFUNCS[kind], keys = keys, bang = not recorded }
    recording = nil
  end
  local text = r.linewise and vim.api.nvim_buf_get_lines(thread, r.srow, r.erow + 1, false)
    or vim.api.nvim_buf_get_text(thread, r.srow, r.scol, r.erow, r.ecol, {})
  if not table.concat(text, ""):find("%S") then
    warn("nothing to annotate here")
    return
  end
  local function same(item)
    local o = A.range(item)
    return o.linewise == r.linewise and o.srow == r.srow and o.erow == r.erow and (r.linewise or (o.scol == r.scol and o.ecol == r.ecol))
  end
  local rekind
  for _, item in pairs(A.items) do
    if same(item) then
      if item.kind == kind then
        rekind = nil
        if kind ~= "comment" then
          if item.sent then
            A.update(item.id, { sent = false })
          end
          return
        end
        break
      elseif item.sent then
        rekind = item
      end
    end
  end
  if rekind then
    if kind == "comment" then
      M.compose({ item = rekind, kind = kind })
    else
      A.update(rekind.id, { kind = kind })
    end
    return
  end
  if kind == "comment" then
    M.compose({ range = r, body = (not was_fresh) and M.last_body or nil })
    return
  end
  r.kind = kind
  A.add(r)
end

for kind, name in pairs(OPFUNCS) do
  M[name] = function(type)
    apply_op(kind, type)
  end
end

local function operator(kind, suffix)
  return function()
    fresh = true
    local rec = { keys = {}, count = vim.v.count, visual = vim.fn.mode():find("^[vV\22]") ~= nil, first = true }
    recording = rec
    vim.on_key(function(_, typed)
      if recording ~= rec then
        return
      end
      if rec.first then
        rec.first = false
      elseif typed and typed ~= "" then
        rec.keys[#rec.keys + 1] = typed
      end
    end, recorder)
    vim.o.operatorfunc = "v:lua.require'vimnotate'." .. OPFUNCS[kind]
    return "g@" .. (suffix or "")
  end
end

local function line_motion(kind, key)
  return function()
    if vim.v.operator == "g@" and vim.o.operatorfunc:find(OPFUNCS[kind], 1, true) then
      return "_"
    end
    return key
  end
end

function M.jump(dir, count)
  local items = A.list()
  if #items == 0 then
    warn("no annotations")
    return
  end
  local tw = thread_win()
  vim.api.nvim_win_call(tw, function()
    vim.cmd("normal! m'")
  end)
  for _ = 1, count or 1 do
    local cur = vim.api.nvim_win_get_cursor(tw)
    local pos = { srow = cur[1] - 1, scol = cur[2] }
    local target
    if dir > 0 then
      for _, item in ipairs(items) do
        local r = A.range(item)
        if before(pos, r) then
          target = r
          break
        end
      end
      target = target or A.range(items[1])
    else
      for i = #items, 1, -1 do
        local r = A.range(items[i])
        if before(r, pos) then
          target = r
          break
        end
      end
      target = target or A.range(items[#items])
    end
    vim.api.nvim_win_set_cursor(tw, { target.srow + 1, target.linewise and 0 or target.scol })
  end
end

function M.hover()
  hint_hide()
  local item = A.at_cursor()
  if not item then
    warn("no annotation under cursor")
    return
  end
  local kind = KINDS[item.kind]
  local body = vim.trim(item.body)
  local lines = body ~= "" and vim.split(body, "\n", { plain = true }) or { "_(no note)_" }
  vim.lsp.util.open_floating_preview(lines, "markdown", {
    border = "rounded",
    title = " " .. kind.glyph .. " " .. A.short_id(item.id) .. " · " .. kind.label .. (item.sent and " · sent " or " "),
    focus_id = "vimnotate_hover",
    max_width = 60,
  })
end

function M.edit()
  local item = A.at_cursor()
  if not item then
    warn("no annotation under cursor")
    return
  end
  M.compose({ item = item })
end

function M.remove_at_cursor()
  local item = A.at_cursor()
  if not item then
    warn("no annotation under cursor")
    return
  end
  A.remove(item.id)
end

local RAIL_WIDTH = 36
local RAIL_MIN_WIDTH = 28
local RAIL_MIN_THREAD = 80
local RAIL_FORCE_MIN_THREAD = 40
local INLINE_INDENT = 2
local FLASH_MS = 2500
local rail_ns = vim.api.nvim_create_namespace("vimnotate.rail")
local inline_ns = vim.api.nvim_create_namespace("vimnotate.inline")
local dw = vim.fn.strdisplaywidth

local function chars(s)
  local out = {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    out[#out + 1] = ch
  end
  return out
end

local function truncate(s, width)
  if dw(s) <= width then
    return s
  end
  local out, w = {}, 0
  for _, ch in ipairs(chars(s)) do
    local cw = dw(ch)
    if w + cw > width - 1 then
      break
    end
    out[#out + 1] = ch
    w = w + cw
  end
  return table.concat(out) .. "…"
end

local function wrap_text(text, width)
  width = math.max(width, 1)
  local out = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    local line, lw = "", 0
    for word in para:gmatch("%S+") do
      local ww = dw(word)
      if lw > 0 and lw + 1 + ww <= width then
        line, lw = line .. " " .. word, lw + 1 + ww
      else
        if lw > 0 then
          out[#out + 1] = line
        end
        line, lw = "", 0
        if ww > width then
          for _, ch in ipairs(chars(word)) do
            local cw = dw(ch)
            if lw > 0 and lw + cw > width then
              out[#out + 1] = line
              line, lw = "", 0
            end
            line, lw = line .. ch, lw + cw
          end
        else
          line, lw = word, ww
        end
      end
    end
    out[#out + 1] = line
  end
  return out
end

local function accent_of(item)
  return "Vimnotate" .. KINDS[item.kind].hl:sub(10) .. "Border" .. (item.sent and "Sent" or "")
end

local function frame(title, accent, lines, text_hl, width, edge, fit)
  if fit then
    local w = dw(title) + 4
    for _, l in ipairs(lines) do
      w = math.max(w, dw(l) + 4)
    end
    width = math.min(width, w)
  end
  title = truncate(title, width - 2)
  local tw = dw(title)
  local rows = { { { "╭", edge }, { title, accent }, { string.rep("─", width - 2 - tw) .. "╮", edge } } }
  for _, l in ipairs(lines) do
    l = truncate(l, width - 4)
    rows[#rows + 1] = { { "│ ", edge }, { l .. string.rep(" ", width - 4 - dw(l)), text_hl }, { " │", edge } }
  end
  rows[#rows + 1] = { { "╰" .. string.rep("─", width - 2) .. "╯", edge } }
  return rows
end

local function bubble(item, width, edge, fit)
  local kind = KINDS[item.kind]
  local title = " " .. kind.glyph .. " " .. A.short_id(item.id) .. (item.sent and " · sent " or " ")
  local body = vim.trim(item.body)
  local lines, text_hl = { kind.label }, "VimnotateLabel"
  if body ~= "" then
    lines, text_hl = wrap_text(body, width - 4), nil
  end
  return frame(title, accent_of(item), lines, text_hl, width, edge, fit)
end

local function cut_rows(b, avail, width)
  local cut = { b[1] }
  for i = 2, avail - 2 do
    cut[#cut + 1] = b[i]
  end
  local last = b[avail - 1]
  cut[#cut + 1] = { last[1], { "…" .. string.rep(" ", width - 5), last[2][2] }, last[3] }
  cut[#cut + 1] = b[#b]
  return cut
end

local pin = { item = { id = "note", note = true }, max_rows = 6 }
M.pin = pin

function pin.on()
  return view.mode == "rail" and note_text() ~= ""
end

function pin.bubble(width, height, edge)
  local b = frame(" ✎ note ", "VimnotateCommentBorder", wrap_text(note_text(), width - 4), nil, width, edge, false)
  local cap = math.min(pin.max_rows, math.max(3, math.floor(height / 2)))
  if #b > cap then
    b = cut_rows(b, cap, width)
  end
  return b
end

local function rail_valid()
  return view.rail_win ~= nil and vim.api.nvim_win_is_valid(view.rail_win)
end

function pin.valid(sel)
  if sel == pin.item then
    return pin.on()
  end
  return sel ~= nil and A.items[sel.id] ~= nil
end

local function selected_item()
  if view.focused then
    return pin.valid(view.sel) and view.sel or nil
  end
  return A.at_cursor()
end

local function paint(buf, rows, height)
  local lines, marks = {}, {}
  for i = 1, height do
    local row = rows[i]
    if row then
      local parts, byte = {}, 0
      for _, ch in ipairs(row) do
        parts[#parts + 1] = ch[1]
        if ch[2] then
          marks[#marks + 1] = { i - 1, byte, byte + #ch[1], ch[2] }
        end
        byte = byte + #ch[1]
      end
      lines[i] = table.concat(parts)
    else
      lines[i] = ""
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, rail_ns, 0, -1)
  for _, mk in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, rail_ns, mk[1], mk[2], { end_col = mk[3], hl_group = mk[4] })
  end
end

local RAIL_HINTS = "j/k ⏎ jump · e edit · x drop · esc"

local function rail_winbar()
  if view.focused then
    return " %<" .. RAIL_HINTS
  end
  return " ANNOTATIONS · %<S-Tab focus"
end

local function anchor_y(tw, top, skip, srow, scol)
  local vcol = 0
  if scol > 0 then
    vcol = dw((vim.api.nvim_buf_get_lines(thread, srow, srow + 1, false)[1] or ""):sub(1, scol))
  end
  if srow > top or (srow == top and vcol >= skip) then
    return vim.api.nvim_win_text_height(tw, { start_row = top, start_vcol = skip, end_row = srow, end_vcol = vcol + 1 }).all - 1
  end
  return -vim.api.nvim_win_text_height(tw, { start_row = srow, start_vcol = vcol, end_row = top, end_vcol = skip }).all
end

local function rail_render()
  local tw = thread_win()
  if not rail_valid() or tw == -1 then
    return
  end
  local rw = view.rail_win
  local width, height = vim.api.nvim_win_get_width(rw), vim.api.nvim_win_get_height(rw)
  local sv = vim.api.nvim_win_call(tw, vim.fn.winsaveview)
  local top, skip = sv.topline - 1, sv.skipcol
  local bot = vim.fn.getwininfo(tw)[1].botline
  local by_mark = {}
  for _, item in pairs(A.items) do
    by_mark[item.mark] = item
  end
  local sel = selected_item()
  local rows, bubbles, next_y = {}, {}, -math.huge
  local floor = 0
  if pin.on() then
    local nb = pin.bubble(width, height, sel == pin.item and "VimnotateCommentBorderBold" or "VimnotateEdge")
    for i, row in ipairs(nb) do
      rows[i] = row
    end
    floor = #nb
    bubbles[1] = { item = pin.item, y0 = 0, y1 = floor - 1, whole = true }
  end
  local marks = vim.api.nvim_buf_get_extmarks(thread, range_ns, { math.max(top - height, 0), 0 }, { bot, -1 }, {})
  for _, mk in ipairs(marks) do
    local item = by_mark[mk[1]]
    if item then
      local y = math.max(anchor_y(tw, top, skip, mk[2], item.linewise and 0 or mk[3]), next_y)
      if y >= height then
        break
      end
      local edge = item == sel and (accent_of(item) .. "Bold") or "VimnotateEdge"
      local b = bubble(item, width, edge, false)
      if floor > 0 and y < floor and y + #b > 0 then
        y = floor
      end
      if floor > 0 and y >= height then
        break
      end
      local whole = y >= 0 and y + #b <= height
      local avail = height - y
      if avail >= 3 and avail < #b then
        b = cut_rows(b, avail, width)
      end
      for i, row in ipairs(b) do
        local ry = y + i - 1
        if ry >= floor and ry < height then
          rows[ry + 1] = row
        end
      end
      if y + #b > 0 then
        bubbles[#bubbles + 1] = { item = item, y0 = math.max(y, 0), y1 = math.min(y + #b, height) - 1, whole = whole }
      end
      next_y = y + #b
    end
  end
  paint(view.rail_buf, rows, height)
  view.bubbles = bubbles
  view.last_sel = sel
  vim.wo[rw].winbar = rail_winbar()
  view.painting = true
  vim.api.nvim_win_call(rw, function()
    local line = 1
    if view.focused and sel then
      for _, b in ipairs(bubbles) do
        if b.item == sel then
          line = b.y0 + 1
        end
      end
    end
    vim.fn.winrestview({ topline = 1, lnum = line, col = 0, leftcol = 0 })
  end)
  view.painting = false
end
M.rail_render = rail_render

local function box_width(info)
  return math.max(info.width - info.textoff - INLINE_INDENT, 12)
end

local function inline_render()
  vim.api.nvim_buf_clear_namespace(thread, inline_ns, 0, -1)
  local tw = thread_win()
  if tw == -1 then
    return
  end
  local width = box_width(vim.fn.getwininfo(tw)[1])
  local c = M.composing()
  local entries = {}
  if view.mode == "inline" then
    for _, item in ipairs(A.list()) do
      if not (c and c.item == item) then
        entries[#entries + 1] = { item = item, r = A.range(item), seq = item.seq }
      end
    end
  end
  if c and c.rows then
    local slot = { r = c.range, seq = c.item and c.item.seq or math.huge }
    local at = #entries + 1
    for i, e in ipairs(entries) do
      if before(slot.r, e.r) or (not before(e.r, slot.r) and slot.seq < e.seq) then
        at = i
        break
      end
    end
    table.insert(entries, at, slot)
  end
  local sel = A.at_cursor()
  local groups = {}
  for _, e in ipairs(entries) do
    local erow = e.r.erow
    groups[erow] = groups[erow] or {}
    if e.item then
      local edge = accent_of(e.item) .. (e.item == sel and "Bold" or "")
      for _, row in ipairs(bubble(e.item, width, edge, true)) do
        table.insert(row, 1, { string.rep(" ", INLINE_INDENT) })
        table.insert(groups[erow], row)
      end
    else
      c.offset = #groups[erow]
      for _ = 1, c.rows do
        table.insert(groups[erow], { { " " } })
      end
    end
  end
  for erow, vl in pairs(groups) do
    vim.api.nvim_buf_set_extmark(thread, inline_ns, erow, 0, { virt_lines = vl })
  end
  view.last_sel = sel
end
M.inline_render = inline_render

local function render_view()
  inline_render()
  if view.mode == "rail" then
    rail_render()
  end
end

local function reveal(tw, c)
  local r = c.range
  local height = vim.fn.getwininfo(tw)[1].height
  local sv = vim.api.nvim_win_call(tw, vim.fn.winsaveview)
  local top = sv.topline - 1
  local extra = (c.offset or 0) + c.rows
  if r.erow < top then
    top = r.srow
  end
  local function used(t)
    return vim.api.nvim_win_text_height(tw, { start_row = t, end_row = r.erow }).all + extra
  end
  while top < r.erow and used(top) > height do
    top = top + 1
  end
  if top ~= sv.topline - 1 then
    vim.api.nvim_win_call(tw, function()
      vim.fn.winrestview({ topline = top + 1, skipcol = 0 })
    end)
  end
end

function M.compose_layout(c)
  local tw = thread_win()
  local info = vim.fn.getwininfo(tw)[1]
  local r = c.range
  local maxw = box_width(info)
  if c.inline then
    c.width = math.max(1, maxw - 4)
  else
    c.width = math.max(1, math.min(c.base_width, info.width - 2))
  end
  local rows = c.height + 2
  if c.inline and c.buf and vim.api.nvim_buf_is_valid(c.buf) then
    local preview = {
      kind = c.kind,
      id = c.item and c.item.id or "anno_00000",
      body = table.concat(vim.api.nvim_buf_get_lines(c.buf, 0, -1, false), "\n"),
    }
    rows = math.max(rows, #bubble(preview, maxw, "VimnotateEdge", true))
  end
  c.rows = rows
  render_view()
  reveal(tw, c)
  info = vim.fn.getwininfo(tw)[1]
  local ecol = r.linewise and math.max(line_len(r.erow) - 1, 0) or math.max(r.ecol - 1, 0)
  local ep = vim.fn.screenpos(tw, r.erow + 1, ecol + 1)
  local x
  if c.inline then
    x = info.textoff + INLINE_INDENT + 1
  else
    local sp = vim.fn.screenpos(tw, r.srow + 1, (r.linewise and 0 or r.scol) + 1)
    x = sp.col > 0 and (sp.col - info.wincol) or 0
  end
  x = math.max(0, math.min(x, info.width - c.width - 2))
  return {
    relative = "win",
    win = tw,
    width = c.width,
    height = c.height,
    bufpos = { r.erow, ecol },
    anchor = "NW",
    row = 1 + (c.offset or 0),
    col = ep.col > 0 and (x - (ep.col - info.wincol)) or x,
  }
end

local function view_setting()
  local v = vim.g.vimnotate_view
  if v == "rail" or v == "auto" or v == "off" then
    return v
  end
  return "inline"
end

local function rail_width(total)
  return math.max(RAIL_MIN_WIDTH, math.min(RAIL_WIDTH, math.floor(total * 3 / 10)))
end

local function total_width(tw)
  local w = vim.api.nvim_win_get_width(tw)
  if rail_valid() then
    w = w + vim.api.nvim_win_get_width(view.rail_win) + 1
  end
  return w
end

local function rail_fits(tw, min)
  local total = total_width(tw)
  return total - rail_width(total) - 1 >= min
end

local function planned(tw)
  local s = view_setting()
  if s == "off" or s == "inline" then
    return s
  end
  if rail_fits(tw, s == "rail" and RAIL_FORCE_MIN_THREAD or RAIL_MIN_THREAD) then
    return "rail"
  end
  return "inline"
end
M.planned = planned

local function wanted(tw)
  if next(A.items) == nil then
    return "off"
  end
  return planned(tw)
end

function M.jumplist(dir, count)
  local tw = thread_win()
  if tw == -1 then
    return
  end
  vim.api.nvim_win_call(tw, function()
    pcall(vim.cmd, "normal! " .. (count or 1) .. (dir < 0 and "\15" or "\t"))
  end)
end

local function scroll_thread(n)
  local tw = thread_win()
  if tw == -1 or n == 0 then
    return
  end
  vim.api.nvim_win_call(tw, function()
    vim.cmd("normal! " .. math.abs(n) .. (n > 0 and "\5" or "\25"))
  end)
end
M.scroll_thread = scroll_thread

local function wheel(key, n)
  return function()
    local m = vim.fn.getmousepos()
    if rail_valid() and m.winid == view.rail_win then
      return "<Cmd>lua require('vimnotate').scroll_thread(" .. n .. ")<CR>"
    end
    return key
  end
end

local function rail_scrub(win)
  local opts = {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    statuscolumn = "",
    colorcolumn = "",
    cursorline = false,
    cursorcolumn = false,
    list = false,
    spell = false,
    wrap = false,
    scrolloff = 0,
    sidescrolloff = 0,
    foldenable = false,
    conceallevel = 0,
    winfixwidth = true,
    winfixbuf = true,
    fillchars = "eob: ",
  }
  for k, v in pairs(opts) do
    vim.wo[win][k] = v
  end
  vim.wo[win].winbar = rail_winbar()
end

local function back_to_thread()
  local tw = thread_win()
  if tw ~= -1 then
    vim.api.nvim_set_current_win(tw)
  end
end

local function rail_index(items)
  for i, it in ipairs(items) do
    if view.sel and it.id == view.sel.id then
      return i
    end
  end
  return nil
end

local function bubble_of(item)
  for _, b in ipairs(view.bubbles) do
    if b.item == item then
      return b
    end
  end
  return nil
end

function pin.items()
  local items = A.list()
  if pin.on() then
    table.insert(items, 1, pin.item)
  end
  return items
end

function M.rail_move(delta)
  local items = pin.items()
  if #items == 0 then
    return
  end
  local idx = rail_index(items) or (delta > 0 and 0 or #items + 1)
  view.sel = items[math.max(1, math.min(#items, idx + delta))]
  rail_render()
  local b = bubble_of(view.sel)
  if view.sel ~= pin.item and not (b and b.whole) then
    local tw = thread_win()
    local r = A.range(view.sel)
    vim.api.nvim_win_call(tw, function()
      vim.fn.winrestview({ topline = math.max(1, r.srow - 1), skipcol = 0, lnum = r.srow + 1, col = r.linewise and 0 or r.scol })
    end)
    rail_render()
  end
end

function M.rail_edge(last)
  local items = pin.items()
  if #items == 0 then
    return
  end
  view.sel = nil
  M.rail_move(last and #items or -#items)
end

function M.rail_jump(item)
  item = item or selected_item()
  local tw = thread_win()
  if not item or tw == -1 then
    return
  end
  if item == pin.item then
    M.note_show()
    return
  end
  local r = A.range(item)
  vim.api.nvim_set_current_win(tw)
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(tw, { r.srow + 1, r.linewise and 0 or r.scol })
end

function M.rail_edit()
  local item = selected_item()
  if item == pin.item then
    M.note_show()
  elseif item then
    M.compose({ item = item })
  end
end

function M.rail_remove()
  local item = selected_item()
  if not item or item == pin.item then
    return
  end
  local items = A.list()
  local idx = rail_index(items) or 1
  view.sel = items[idx + 1] or items[idx - 1]
  A.remove(item.id)
end

function M.rail_click(line)
  if vim.api.nvim_get_mode().mode:find("^[vV\22]") then
    vim.cmd("normal! \27")
  end
  for _, b in ipairs(view.bubbles) do
    if line - 1 >= b.y0 and line - 1 <= b.y1 then
      M.rail_jump(b.item)
      return
    end
  end
end

function M.rail_focus()
  if rail_valid() then
    vim.api.nvim_set_current_win(view.rail_win)
  else
    warn("rail is not shown (R cycles the view)")
  end
end

local function rail_buffer()
  if view.rail_buf and vim.api.nvim_buf_is_valid(view.rail_buf) then
    return view.rail_buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = false
  view.rail_buf = buf
  local o = { buffer = buf, nowait = true }
  local function count(dir)
    return function()
      M.rail_move(dir * vim.v.count1)
    end
  end
  vim.keymap.set("n", "j", count(1), o)
  vim.keymap.set("n", "k", count(-1), o)
  vim.keymap.set("n", "<Down>", count(1), o)
  vim.keymap.set("n", "<Up>", count(-1), o)
  vim.keymap.set("n", "gg", function()
    M.rail_edge(false)
  end, o)
  vim.keymap.set("n", "G", function()
    M.rail_edge(true)
  end, o)
  vim.keymap.set("n", "<CR>", function()
    M.rail_jump()
  end, o)
  vim.keymap.set("n", "e", M.rail_edit, o)
  vim.keymap.set("n", "x", M.rail_remove, o)
  vim.keymap.set("n", "R", function()
    M.cycle_view()
  end, o)
  vim.keymap.set("n", "q", "<Cmd>qa<CR>", o)
  vim.keymap.set("n", "u", function()
    M.undo()
  end, o)
  vim.keymap.set("n", "<C-r>", function()
    M.redo()
  end, o)
  for _, s in ipairs({ { "<C-o>", -1 }, { "<C-i>", 1 } }) do
    vim.keymap.set("n", s[1], function()
      local n = vim.v.count1
      back_to_thread()
      M.jumplist(s[2], n)
    end, o)
  end
  for _, lhs in ipairs(M.BUFFER_SWITCHERS) do
    vim.keymap.set("n", lhs, "<Nop>", o)
  end
  for _, lhs in ipairs({ "<Esc>", "h", "<S-Tab>", "<Tab>" }) do
    vim.keymap.set("n", lhs, back_to_thread, o)
  end
  for _, lhs in ipairs({ "H", "L", "l", "<2-LeftMouse>", "<3-LeftMouse>", "<LeftDrag>", "<LeftRelease>" }) do
    vim.keymap.set("n", lhs, "<Nop>", o)
  end
  vim.keymap.set("n", "<LeftMouse>", function()
    local m = vim.fn.getmousepos()
    if m.winid ~= view.rail_win then
      return "<LeftMouse>"
    end
    pending_click = function()
      M.rail_click(m.line)
    end
    swallow = true
    return "<Cmd>lua require('vimnotate').bar_click()<CR>"
  end, { buffer = buf, nowait = true, expr = true })
  for _, s in ipairs({ { "<ScrollWheelDown>", 3 }, { "<ScrollWheelUp>", -3 }, { "<C-e>", 1 }, { "<C-y>", -1 } }) do
    vim.keymap.set("n", s[1], function()
      scroll_thread(s[2] * (s[1]:find("Wheel") and 1 or vim.v.count1))
    end, o)
  end
  for _, s in ipairs({ { "<C-d>", 1 }, { "<C-u>", -1 } }) do
    vim.keymap.set("n", s[1], function()
      local tw = thread_win()
      if tw ~= -1 then
        scroll_thread(s[2] * math.floor(vim.api.nvim_win_get_height(tw) / 2))
      end
    end, o)
  end
  local group = vim.api.nvim_create_augroup("vimnotate.rail", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      view.focused = true
      bars_hide()
      if not pin.valid(view.sel) then
        view.sel = A.at_cursor() or (view.bubbles[1] and view.bubbles[1].item) or pin.items()[1]
      end
      rail_render()
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      view.focused = false
      view.sel = nil
      vim.schedule(rail_render)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    callback = function()
      if view.painting or not view.focused then
        return
      end
      local line = vim.api.nvim_win_get_cursor(0)[1] - 1
      for _, b in ipairs(view.bubbles) do
        if line >= b.y0 and line <= b.y1 and b.item ~= view.sel then
          view.sel = b.item
          rail_render()
          return
        end
      end
    end,
  })
  return buf
end

local function rail_open(tw)
  local width = rail_width(total_width(tw))
  if rail_valid() then
    if vim.api.nvim_win_get_width(view.rail_win) ~= width then
      vim.api.nvim_win_set_width(view.rail_win, width)
    end
    return
  end
  view.rail_win = vim.api.nvim_open_win(rail_buffer(), false, { split = "right", win = tw, width = width })
  rail_scrub(view.rail_win)
end

local function rail_close()
  if rail_valid() then
    local win = view.rail_win
    view.rail_win = nil
    vim.api.nvim_win_close(win, true)
  end
  view.rail_win = nil
  view.focused = false
  view.bubbles = {}
end

local function apply_view()
  local tw = thread_win()
  if view.applying or tw == -1 then
    return
  end
  view.applying = true
  local want = wanted(tw)
  if want ~= "rail" then
    rail_close()
  end
  view.mode = want
  if want == "rail" and not rail_valid() then
    rail_open(tw)
    vim.schedule(render_view)
  elseif want == "rail" then
    rail_open(tw)
  end
  render_view()
  view.applying = false
end
M.apply_view = apply_view

local function flash(text)
  view.flash = text
  view.flash_token = (view.flash_token or 0) + 1
  local token = view.flash_token
  refresh_winbar()
  vim.defer_fn(function()
    if view.flash_token == token then
      view.flash = nil
      refresh_winbar()
    end
  end, FLASH_MS)
end
M.flash = flash

function M.cycle_view()
  local tw = thread_win()
  if tw == -1 then
    return
  end
  local order = { "inline", "rail", "off" }
  local cur = view_setting()
  if cur == "auto" then
    cur = planned(tw)
  end
  local idx = 3
  for i, v in ipairs(order) do
    if v == cur then
      idx = i
    end
  end
  local nxt
  for step = 1, 3 do
    local cand = order[(idx - 1 + step) % 3 + 1]
    if cand ~= "rail" or rail_fits(tw, RAIL_FORCE_MIN_THREAD) then
      nxt = cand
      break
    end
  end
  vim.g.vimnotate_view = nxt
  back_to_thread()
  apply_view()
  local note = nxt == "rail" and " (S-Tab focus)" or ""
  if nxt ~= "off" and next(A.items) == nil then
    note = " (shown with the first annotation)"
  end
  flash("view: " .. nxt .. note)
end

local view_group = vim.api.nvim_create_augroup("vimnotate.view", { clear = true })
local resize_pending = false
vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
  group = view_group,
  callback = function()
    render_view()
    if resize_pending then
      return
    end
    resize_pending = true
    vim.schedule(function()
      resize_pending = false
      apply_view()
    end)
  end,
})
vim.api.nvim_create_autocmd("WinScrolled", {
  group = view_group,
  callback = function()
    if view.mode ~= "rail" or not rail_valid() then
      return
    end
    local ev = vim.v.event[tostring(view.rail_win)]
    if ev and ev.topline > 0 and vim.fn.line("w0", view.rail_win) > 1 then
      scroll_thread(ev.topline)
    end
    rail_render()
  end,
})
vim.api.nvim_create_autocmd("CursorMoved", {
  group = view_group,
  buffer = thread,
  callback = function()
    if view.mode ~= "off" and not view.focused and A.at_cursor() ~= view.last_sel then
      render_view()
    end
  end,
})
vim.api.nvim_create_autocmd("WinClosed", {
  group = view_group,
  callback = function(ev)
    local win = tonumber(ev.match)
    if win == view.rail_win then
      view.rail_win = nil
      view.focused = false
      if not view.applying then
        vim.g.vimnotate_view = "off"
        view.mode = "off"
      end
    elseif win == thread_win() and rail_valid() then
      vim.schedule(function()
        if #vim.tbl_filter(function(w)
          return vim.api.nvim_win_get_config(w).relative == ""
        end, vim.api.nvim_list_wins()) <= 1 then
          vim.cmd("qa")
        else
          rail_close()
        end
      end)
    end
  end,
})
A.on_change(function()
  vim.schedule(apply_view)
end)
M.wheel = wheel
M.rail_scrub = function()
  if rail_valid() then
    rail_scrub(view.rail_win)
  end
end

local NOTE_MIN_WIDTH = 40
local NOTE_MAX_WIDTH = 100
local NOTE_MIN_HEIGHT = 6
local NOTE_MAX_HEIGHT = 24
M.NOTE_TITLES = {
  insert = { "note · sent first · esc normal", "note · esc normal" },
  normal = { "note · sent first · q/Tab close · i insert", "note · q/Tab close · i insert", "note · q/Tab close" },
}

local function note_title(width)
  local insert = note_shown() and vim.api.nvim_get_current_win() == note_win and vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
  local options = M.NOTE_TITLES[insert and "insert" or "normal"]
  for _, t in ipairs(options) do
    if dw(t) + 2 <= width then
      return " " .. t .. " "
    end
  end
  return truncate(" " .. options[#options] .. " ", width)
end
M.note_title = note_title

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function note_layout()
  local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local width = math.max(1, math.min(cols - 2, clamp(math.floor(cols * 0.7), NOTE_MIN_WIDTH, NOTE_MAX_WIDTH)))
  local height = math.max(1, math.min(rows - 2, clamp(math.floor(rows * 0.45), NOTE_MIN_HEIGHT, NOTE_MAX_HEIGHT)))
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((rows - height - 2) / 2)),
    col = math.max(0, math.floor((cols - width - 2) / 2)),
    title = note_title(width),
    title_pos = "left",
  }
end
M.note_layout = note_layout

function M.note_shown()
  return note_shown()
end

function M.note_hide()
  if not note_shown() then
    return
  end
  local win = note_win
  if vim.api.nvim_get_current_win() == win then
    back_to_thread()
  end
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    vim.cmd("stopinsert")
  end
  refresh_winbar()
  rail_render()
end

local function note_keys(buf)
  local o = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q", M.note_hide, o)
  vim.keymap.set("n", "<Tab>", M.note_hide, o)
  vim.keymap.set("n", "H", "H", o)
  vim.keymap.set("n", "L", "L", o)
  for _, lhs in ipairs(M.BUFFER_SWITCHERS) do
    vim.keymap.set("n", lhs, "<Nop>", o)
  end
end

function M.note_open()
  if note_shown() then
    vim.api.nvim_set_current_win(note_win)
    return note_win
  end
  bars_hide()
  local fresh = not (note_buf and vim.api.nvim_buf_is_valid(note_buf))
  local buf = note_buf
  if fresh then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
  end
  local cfg = note_layout()
  cfg.border = "rounded"
  cfg.style = "minimal"
  local win = vim.api.nvim_open_win(buf, false, cfg)
  note_win = win
  vim.wo[win].winfixbuf = false
  vim.wo[win].conceallevel = 2
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = "FloatBorder:VimnotateCommentBorder,FloatTitle:VimnotateTitle"
  vim.api.nvim_set_current_win(win)
  if fresh then
    vim.cmd("edit " .. vim.fn.fnameescape(note_path))
    note_buf = vim.api.nvim_get_current_buf()
    markdown_warm = true
    if vim.bo[note_buf].filetype ~= "markdown" then
      vim.bo[note_buf].filetype = "markdown"
    end
    vim.bo[note_buf].swapfile = false
    vim.bo[note_buf].undofile = false
    vim.bo[note_buf].bufhidden = "hide"
    note_keys(note_buf)
    hide_chrome()
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = vim.api.nvim_create_augroup("vimnotate.note_text", { clear = true }),
      buffer = note_buf,
      callback = function()
        refresh_winbar()
        rail_render()
      end,
    })
  end
  vim.wo[win].winfixbuf = true
  return win
end

function M.note_show()
  if note_shown() then
    vim.api.nvim_set_current_win(note_win)
    return
  end
  local win = M.note_open()
  local lines = vim.api.nvim_buf_get_lines(note_buf, 0, -1, false)
  local last = #lines
  while last > 1 and not lines[last]:find("%S") do
    last = last - 1
  end
  vim.api.nvim_win_set_cursor(win, { last, math.max(#lines[last] - 1, 0) })
  if note_text() == "" then
    vim.cmd("startinsert!")
  end
end

function M.note_toggle()
  if note_shown() then
    M.note_hide()
  else
    M.note_show()
  end
end

function _G.vimnotate_note_click(_, _, button)
  if button == "l" then
    vim.schedule(M.note_show)
  end
end

local function quote_into_note(lines)
  if #lines == 0 then
    return
  end
  local win = M.note_open()
  local content = vim.api.nvim_buf_get_lines(note_buf, 0, -1, false)
  while #content > 0 and content[#content]:match("^%s*$") do
    table.remove(content)
  end
  if #content > 0 then
    content[#content + 1] = ""
  end
  for _, l in ipairs(lines) do
    content[#content + 1] = ("> " .. l):gsub("%s+$", "")
  end
  content[#content + 1] = ""
  content[#content + 1] = ""
  vim.api.nvim_buf_set_lines(note_buf, 0, -1, false, content)
  vim.api.nvim_win_set_cursor(win, { #content, 0 })
  vim.cmd("startinsert")
end

local note_group = vim.api.nvim_create_augroup("vimnotate.note", { clear = true })
vim.api.nvim_create_autocmd("WinLeave", {
  group = note_group,
  callback = function()
    if not note_shown() or vim.api.nvim_get_current_win() ~= note_win then
      return
    end
    vim.schedule(function()
      local cur = vim.api.nvim_get_current_win()
      if note_shown() and cur ~= note_win and vim.api.nvim_win_get_config(cur).relative == "" then
        M.note_hide()
      end
    end)
  end,
})
vim.api.nvim_create_autocmd("ModeChanged", {
  group = note_group,
  callback = function()
    if note_shown() then
      vim.api.nvim_win_set_config(note_win, { title = note_title(vim.api.nvim_win_get_width(note_win)), title_pos = "left" })
    end
  end,
})
vim.api.nvim_create_autocmd("VimResized", {
  group = note_group,
  callback = function()
    if note_shown() then
      vim.api.nvim_win_set_config(note_win, note_layout())
    end
  end,
})
vim.api.nvim_create_autocmd("WinClosed", {
  group = note_group,
  callback = function(ev)
    if note_win and tonumber(ev.match) == note_win then
      note_win = nil
      vim.schedule(function()
        refresh_winbar()
        rail_render()
      end)
    end
  end,
})

local function quote_lines(lines)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = ("> " .. l):gsub("%s+$", "")
  end
  return table.concat(out, "\n")
end

local function reply_text(body)
  return (body:gsub("^(%s*)>", "%1\\>"):gsub("\n(%s*)>", "\n%1\\>"))
end

function M.export()
  local parts = {}
  local note = note_text()
  if note ~= "" then
    parts[#parts + 1] = note
  end
  local items = vim.tbl_filter(function(item)
    return not item.sent
  end, A.list())
  for _, item in ipairs(items) do
    local body = reply_text(vim.trim(item.body))
    local reply = body
    if item.kind == "delete" then
      reply = body == "" and "Remove this." or body:find("\n") and ("Remove this.\n" .. body) or ("Remove this. " .. body)
    elseif item.kind == "good" then
      reply = body == "" and "Looks good." or ("Looks good.\n" .. body)
    end
    local block = quote_lines(A.text(item))
    if reply ~= "" then
      block = block .. "\n\n" .. reply
    end
    parts[#parts + 1] = block
  end
  return table.concat(parts, "\n\n")
end

local hay = nil

local function find_all(text)
  local needle = text:gsub("%s+", "")
  if needle == "" then
    return {}, 0
  end
  if not hay then
    local chars_, rows, cols = {}, {}, {}
    for r, l in ipairs(vim.api.nvim_buf_get_lines(thread, 0, -1, false)) do
      for pos, ch in l:gmatch("()(%S)") do
        chars_[#chars_ + 1] = ch
        rows[#rows + 1] = r - 1
        cols[#cols + 1] = pos - 1
      end
    end
    hay = { s = table.concat(chars_), rows = rows, cols = cols }
  end
  local out, init = {}, 1
  while true do
    local s = hay.s:find(needle, init, true)
    if not s then
      break
    end
    local e = s + #needle - 1
    out[#out + 1] = {
      srow = hay.rows[s],
      scol = hay.cols[s],
      erow = hay.rows[e],
      ecol = hay.cols[e] + 1,
      linewise = false,
      full = (s == 1 or hay.rows[s - 1] ~= hay.rows[s]) and (e == #hay.rows or hay.rows[e + 1] ~= hay.rows[e]),
    }
    init = s + 1
  end
  return out, vim.fn.strchars(needle)
end

local function candidates(text, linewise)
  local found, len = find_all(text)
  if not linewise then
    return found, len
  end
  return vim.tbl_filter(function(r)
    return r.full
  end, found), len
end

local CONTEXT_LINES = 5
local CONTEXT_CHARS = 200

local function context(row, step)
  local out, total = {}, 0
  local last = vim.api.nvim_buf_line_count(thread) - 1
  while row >= 0 and row <= last and #out < CONTEXT_LINES and total < CONTEXT_CHARS do
    local l = single_line(vim.api.nvim_buf_get_lines(thread, row, row + 1, false)[1] or "")
    if l ~= "" then
      out[#out + 1] = l
      total = total + #(l:gsub("%s", ""))
    end
    row = row + step
  end
  return out
end

local function context_score(saved, got)
  local score = 0
  if type(saved) ~= "table" then
    return 0
  end
  for i, l in ipairs(saved) do
    if got[i] ~= l then
      break
    end
    score = score + #l
  end
  return score
end

local STATE_VERSION = 1
local target_pane = vim.env.VIMNOTATE_TARGET_PANE or ""
local server = vim.env.VIMNOTATE_SERVER or ""
local carried = {}

local function entry(item)
  local r = A.range(item)
  local text = table.concat(A.text(item), "\n")
  local occ
  for i, c in ipairs((candidates(text, item.linewise))) do
    if c.srow > r.srow or (c.srow == r.srow and c.scol >= r.scol) then
      occ = i
      break
    end
  end
  return {
    kind = item.kind,
    body = item.body,
    text = text,
    linewise = item.linewise,
    before = context(r.srow - 1, -1),
    after = context(r.erow + 1, 1),
    occ = occ,
  }
end

local function entry_key(e)
  return vim.json.encode({ e.kind, e.body, e.text, e.linewise and true or false, e.before or {}, e.after or {}, e.occ or 0 })
end

local function save_state()
  if not state_path then
    return
  end
  local items, seen = {}, {}
  local function push(e)
    local k = entry_key(e)
    if not seen[k] then
      seen[k] = true
      items[#items + 1] = e
    end
  end
  for _, item in ipairs(A.list()) do
    push(entry(item))
  end
  for _, e in ipairs(carried) do
    push(e)
  end
  local dir = vim.fn.fnamemodify(state_path, ":h")
  pcall(vim.fn.mkdir, dir, "p", 448)
  vim.uv.fs_chmod(dir, 448)
  local tmp = state_path .. ".tmp." .. vim.fn.getpid()
  local fd = vim.uv.fs_open(tmp, "w", 384)
  if not fd then
    return
  end
  vim.uv.fs_fchmod(fd, 384)
  local data = vim.json.encode({ version = STATE_VERSION, server = server, pane = target_pane, items = items })
  local wrote = vim.uv.fs_write(fd, data)
  local closed = vim.uv.fs_close(fd)
  if wrote ~= #data or not closed or not vim.uv.fs_rename(tmp, state_path) then
    os.remove(tmp)
  end
end

local function flush()
  if cancelled then
    return
  end
  if compose then
    compose_finish(true)
  end
  local text = M.export()
  if text == "" then
    os.remove(reply_path)
  else
    local out = assert(io.open(reply_path, "wb"))
    out:write(text, "\n")
    out:close()
  end
  local ok, err = pcall(save_state)
  if not ok then
    warn("vimnotate state: " .. tostring(err))
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", { callback = flush })
vim.api.nvim_create_user_command("Cancel", function()
  cancelled = true
  os.remove(reply_path)
  vim.cmd("qa!")
end, { range = true })
vim.api.nvim_create_user_command("Send", function()
  flush()
  cancelled = true
  vim.cmd("qa!")
end, { range = true })

local bo = { buffer = thread, nowait = true }
local ebo = { buffer = thread, nowait = true, expr = true }
vim.keymap.set("n", "c", operator("comment"), ebo)
vim.keymap.set("n", "d", operator("delete"), ebo)
vim.keymap.set("n", "p", operator("good"), ebo)
vim.keymap.set("n", "cw", operator("comment", "w"), ebo)
vim.keymap.set("n", "C", operator("comment", "_"), ebo)
vim.keymap.set("x", "c", operator("comment"), ebo)
vim.keymap.set("x", "C", operator("comment"), ebo)
vim.keymap.set("x", "d", operator("delete"), ebo)
vim.keymap.set("x", "p", operator("good"), ebo)
vim.keymap.set("o", "c", line_motion("comment", "c"), ebo)
vim.keymap.set("o", "d", line_motion("delete", "d"), ebo)
vim.keymap.set("o", "p", line_motion("good", "p"), ebo)
local repeatable_jump = nil
local function jump_key(dir)
  return function()
    if repeatable_jump == nil then
      repeatable_jump = false
      local ok, rm = pcall(require, "nvim-treesitter-textobjects.repeatable_move")
      if ok and type(rm) == "table" and type(rm.make_repeatable_move) == "function" then
        repeatable_jump = rm.make_repeatable_move(function(opts)
          M.jump(opts.forward and 1 or -1, vim.v.count1)
        end)
      end
    end
    if repeatable_jump then
      repeatable_jump({ forward = dir > 0 })
    else
      M.jump(dir, vim.v.count1)
    end
  end
end
vim.keymap.set("n", "]a", jump_key(1), bo)
vim.keymap.set("n", "[a", jump_key(-1), bo)
vim.keymap.set("n", "K", M.hover, bo)
vim.keymap.set("n", "u", function()
  M.undo()
end, bo)
vim.keymap.set("n", "<C-r>", function()
  M.redo()
end, bo)
vim.keymap.set("n", "<C-o>", function()
  M.jumplist(-1, vim.v.count1)
end, bo)
vim.keymap.set("n", "<C-i>", function()
  M.jumplist(1, vim.v.count1)
end, bo)
for _, lhs in ipairs(M.BUFFER_SWITCHERS) do
  vim.keymap.set("n", lhs, "<Nop>", bo)
end
vim.keymap.set("n", "e", M.edit, bo)
vim.keymap.set("n", "x", M.remove_at_cursor, bo)
vim.keymap.set("n", "q", "<Cmd>qa<CR>", bo)
vim.keymap.set("n", "<Tab>", M.note_toggle, bo)
vim.keymap.set("n", "<S-Tab>", M.rail_focus, bo)
vim.keymap.set("n", "R", M.cycle_view, bo)
vim.keymap.set("n", "H", "H", bo)
vim.keymap.set("n", "L", "L", bo)
vim.keymap.set("n", "<ScrollWheelDown>", M.wheel("<ScrollWheelDown>", 3), ebo)
vim.keymap.set("n", "<ScrollWheelUp>", M.wheel("<ScrollWheelUp>", -3), ebo)
unshadow_triggers()

vim.wo.winbar = thread_winbar()
hide_chrome()

local function find_in_thread(text)
  local all = find_all(text)
  return all[#all]
end
M.find_in_thread = find_in_thread

local RESTORE_MIN_CHARS = 8

local function read_state()
  local fh = io.open(state_path, "rb")
  if not fh then
    return nil
  end
  local raw = fh:read("*a")
  fh:close()
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" or type(data.items) ~= "table" then
    return nil
  end
  if data.version ~= STATE_VERSION or data.pane ~= target_pane or data.server ~= server then
    return nil
  end
  local items, seen = {}, {}
  for _, e in ipairs(data.items) do
    if type(e) == "table" and type(e.text) == "string" and KINDS[e.kind] then
      e.body = type(e.body) == "string" and e.body or ""
      e.linewise = e.linewise == true
      e.before = type(e.before) == "table" and e.before or {}
      e.after = type(e.after) == "table" and e.after or {}
      e.occ = type(e.occ) == "number" and e.occ or nil
      local k = entry_key(e)
      if not seen[k] then
        seen[k] = true
        items[#items + 1] = e
      end
    end
  end
  return items
end

local function locate(saved, taken)
  local found, len = candidates(saved.text, saved.linewise)
  local best, best_score, best_dist
  for i, r in ipairs(found) do
    if saved.linewise then
      r.linewise, r.scol, r.ecol = true, 0, line_len(r.erow)
    end
    local key = table.concat({ r.srow, r.scol, r.erow, r.ecol, saved.kind, saved.body }, "\0")
    if not taken[key] then
      local sc = context_score(saved.before, context(r.srow - 1, -1)) + context_score(saved.after, context(r.erow + 1, 1))
      if sc > 0 or (r.full and len >= RESTORE_MIN_CHARS) then
        local dist = saved.occ and math.abs(i - saved.occ) or 0
        if not best or sc > best_score or (sc == best_score and dist <= best_dist) then
          r.key = key
          best, best_score, best_dist = r, sc, dist
        end
      end
    end
  end
  return best
end

local function restore_sent()
  if not state_path then
    return
  end
  local items = read_state()
  if not items then
    return
  end
  if vim.g.vimnotate_restore == false then
    carried = items
    return
  end
  local restored, missing, taken = 0, 0, {}
  H.muted = true
  local ok, err = pcall(function()
    for _, saved in ipairs(items) do
      local r = locate(saved, taken)
      if r then
        taken[r.key] = true
        A.add({ srow = r.srow, scol = r.scol, erow = r.erow, ecol = r.ecol, linewise = r.linewise, kind = saved.kind, body = saved.body, sent = true })
        restored = restored + 1
      else
        carried[#carried + 1] = saved
        missing = missing + 1
      end
    end
  end)
  H.muted = false
  if not ok then
    warn("vimnotate restore: " .. tostring(err))
  end
  if restored + missing > 0 then
    M.flash("restored " .. restored .. " sent" .. (missing > 0 and (", " .. missing .. " not found") or ""))
  end
end

restore_sent()
apply_view()

local anchored = false
local selected_path = vim.env.VIMNOTATE_SELECTED
if selected_path and selected_path ~= "" then
  local sf = io.open(selected_path, "rb")
  if sf then
    local selected = sf:read("*a"):gsub("%s+$", "")
    sf:close()
    if selected ~= "" then
      local r = find_in_thread(selected)
      if r then
        anchored = true
        vim.cmd("normal! m'")
        vim.api.nvim_win_set_cursor(0, { r.srow + 1, r.scol })
        vim.cmd("normal! zz")
        M.compose({ range = r })
      else
        quote_into_note(vim.split(selected, "\n", { plain = true }))
      end
    end
  end
end

vim.defer_fn(function()
  hide_chrome()
  prewarm_markdown()
  unshadow_triggers()
  local tw = thread_win()
  if tw ~= -1 then
    scrub_win(tw)
    vim.wo[tw].winbar = thread_winbar()
    M.rail_scrub()
    apply_view()
    if not anchored then
      vim.api.nvim_win_call(tw, function()
        vim.cmd("normal! G")
      end)
    end
  end
end, 200)

vim.defer_fn(function()
  hide_chrome()
  unshadow_triggers()
  scrub_win(thread_win())
  M.rail_scrub()
  apply_view()
end, 1500)
