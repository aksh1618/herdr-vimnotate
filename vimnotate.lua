local raw_path = vim.env.VIMNOTATE_RAW
local reply_path = vim.env.VIMNOTATE_REPLY
local note_path = vim.fn.fnamemodify(reply_path, ":h") .. "/note.md"

local M = {}
package.loaded["vimnotate"] = M

local cancelled = false
local note_buf = nil

vim.o.swapfile = false
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
end
scrub_win(vim.api.nvim_get_current_win())
vim.cmd("normal! G")

local function thread_win()
  return vim.fn.bufwinid(thread)
end
M.thread_win = thread_win

local function note_win()
  if note_buf and vim.api.nvim_buf_is_valid(note_buf) then
    return vim.fn.bufwinid(note_buf)
  end
  return -1
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
end
define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { callback = define_highlights })

local A = { items = {}, listeners = {} }
M.annotations = A
local range_ns = vim.api.nvim_create_namespace("vimnotate.ranges")
local mark_ns = vim.api.nvim_create_namespace("vimnotate.marks")
A.range_ns = range_ns
A.mark_ns = mark_ns

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
    hl_group = kind.hl,
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
    virt_text = { { " " .. kind.glyph .. " " .. A.short_id(item.id), kind.mark } },
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

function A.add(spec)
  seq = seq + 1
  local item = { id = new_id(), kind = spec.kind, linewise = spec.linewise or false, body = spec.body or "", seq = seq }
  place(item, spec)
  A.items[item.id] = item
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
  if fields.body ~= nil then
    item.body = fields.body
  end
  if fields.kind and fields.kind ~= item.kind then
    item.kind = fields.kind
    place(item, A.range(item))
  end
  emit("update", item)
  return item
end

function A.remove(id)
  local item = A.items[id]
  if not item then
    return nil
  end
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
  return kind.glyph .. " " .. A.short_id(item.id) .. " " .. kind.label .. ": " .. detail
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

local HINTS = "c d + {motion} comment/delete/good · ]a [a · K show · e edit · x drop · Tab note · q send"
local NOTE_HINTS = "general note, sent above the annotations · Tab thread · :qa send · :Cancel discard"

local function thread_winbar()
  local counts = {}
  for _, item in pairs(A.items) do
    counts[item.kind] = (counts[item.kind] or 0) + 1
  end
  local tally = {}
  for _, k in ipairs({ "comment", "delete", "good" }) do
    if counts[k] then
      tally[#tally + 1] = KINDS[k].glyph .. counts[k]
    end
  end
  local head = #tally > 0 and ("THREAD " .. table.concat(tally, " ")) or "THREAD"
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

local function unshadow(mode, lhs)
  local prefix = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  local umbrella = mode == "x" and "v" or mode
  for _, m in ipairs(vim.fn.maplist()) do
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

local TRIGGERS = {
  n = { "c", "d", "+", "a", "x", "e", "K", "]a", "[a", "q", "<Tab>" },
  x = { "c", "d", "+", "a", "<CR>" },
  o = { "c", "d", "+" },
}
M.TRIGGERS = TRIGGERS

local function unshadow_triggers()
  for mode, keys in pairs(TRIGGERS) do
    for _, lhs in ipairs(keys) do
      unshadow(mode, lhs)
    end
  end
end
M.unshadow_triggers = unshadow_triggers

local function ensure_note()
  local win = note_win()
  if win ~= -1 then
    return win
  end
  local cur = vim.api.nvim_get_current_win()
  vim.cmd("topleft 10split " .. vim.fn.fnameescape(note_path))
  note_buf = vim.api.nvim_get_current_buf()
  markdown_warm = true
  vim.bo[note_buf].filetype = "markdown"
  vim.bo[note_buf].swapfile = false
  win = vim.api.nvim_get_current_win()
  vim.wo[win].winbar = "NOTE · %<" .. NOTE_HINTS
  vim.keymap.set("n", "<Tab>", function()
    local tw = thread_win()
    if tw ~= -1 then
      vim.api.nvim_set_current_win(tw)
    end
  end, { buffer = note_buf })
  hide_chrome()
  vim.api.nvim_set_current_win(cur)
  return win
end
M.ensure_note = ensure_note

local function quote_into_note(lines)
  if #lines == 0 then
    return
  end
  local win = ensure_note()
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
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { #content, 0 })
  vim.cmd("startinsert")
end

local pending_ns = vim.api.nvim_create_namespace("vimnotate.pending")
local COMPOSE_MIN_WIDTH = 48
local COMPOSE_MAX_ROWS = 8
local compose = nil

local function compose_title(c, insert)
  local verb = c.item and "edit" or "comment"
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

local function float_config(r, width, height)
  local tw = thread_win()
  local info = vim.fn.getwininfo(tw)[1]
  local top = info.winrow + (info.winbar or 0)
  width = math.max(1, math.min(width, info.width - 2))
  local scol = r.linewise and 0 or r.scol
  local sp = vim.fn.screenpos(tw, r.srow + 1, scol + 1)
  local x = sp.col > 0 and (sp.col - info.wincol) or 0
  x = math.max(0, math.min(x, info.width - width - 2))
  local cfg = { relative = "win", win = tw, width = width, height = height }
  if sp.row > 0 and sp.row - top >= height + 2 then
    cfg.bufpos = { r.srow, scol }
    cfg.anchor = "SW"
    cfg.row = 0
    cfg.col = x - (sp.col - info.wincol)
  else
    local ecol = r.linewise and math.max(line_len(r.erow) - 1, 0) or math.max(r.ecol - 1, 0)
    local ep = vim.fn.screenpos(tw, r.erow + 1, ecol + 1)
    cfg.bufpos = { r.erow, ecol }
    cfg.anchor = "NW"
    cfg.row = 1
    cfg.col = ep.col > 0 and (x - (ep.col - info.wincol)) or x
  end
  return cfg
end

local function compose_resize(c)
  if not vim.api.nvim_win_is_valid(c.win) then
    return
  end
  local h = vim.api.nvim_win_text_height(c.win, {}).all
  h = math.max(1, math.min(h, COMPOSE_MAX_ROWS))
  if h ~= c.height then
    c.height = h
    local cfg = float_config(c.range, c.width, h)
    cfg.title = compose_title(c)
    cfg.title_pos = "left"
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
  if vim.api.nvim_win_is_valid(c.win) then
    vim.api.nvim_win_close(c.win, true)
  end
  if save then
    if c.item then
      if A.items[c.item.id] then
        if body == "" and c.item.kind == "comment" then
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
  local item = opts.item
  local r = item and A.range(item) or opts.range
  local accent = KINDS[item and item.kind or "comment"]
  local c = { item = item, range = r, height = 1 }
  if not item then
    vim.api.nvim_buf_set_extmark(thread, pending_ns, r.srow, r.linewise and 0 or r.scol, {
      end_row = r.erow,
      end_col = r.linewise and line_len(r.erow) or r.ecol,
      hl_group = "Visual",
      hl_eol = r.linewise or nil,
      priority = 4300,
    })
  end
  c.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[c.buf].bufhidden = "wipe"
  local body = opts.body or (item and item.body) or ""
  vim.api.nvim_buf_set_lines(c.buf, 0, -1, false, vim.split(body, "\n", { plain = true }))
  compose = c
  local title = compose_title(c, true)
  c.width = math.max(COMPOSE_MIN_WIDTH, vim.fn.strdisplaywidth(title) + 2, vim.fn.strdisplaywidth(compose_title(c, false)) + 2)
  local cfg = float_config(r, c.width, 1)
  cfg.border = "rounded"
  cfg.style = "minimal"
  cfg.title = title
  cfg.title_pos = "left"
  c.win = vim.api.nvim_open_win(c.buf, true, cfg)
  vim.wo[c.win].conceallevel = 2
  markdown_warm = true
  vim.bo[c.buf].filetype = "markdown"
  vim.wo[c.win].wrap = true
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
  if kind == "comment" then
    M.compose({ range = r, body = (not was_fresh) and M.last_body or nil })
    return
  end
  for _, item in pairs(A.items) do
    local o = A.range(item)
    if item.kind == kind and o.linewise == r.linewise and o.srow == r.srow and o.erow == r.erow and (r.linewise or (o.scol == r.scol and o.ecol == r.ecol)) then
      return
    end
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
    title = " " .. kind.glyph .. " " .. A.short_id(item.id) .. " · " .. kind.label .. " ",
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

local function fenced(text)
  local longest = 0
  for run in text:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  local fence = string.rep("`", math.max(longest, 2) + 1)
  return fence .. "\n" .. text .. "\n" .. fence
end

local function quote_lines(text)
  return "> " .. text:gsub("\n", "\n> ")
end

function M.export()
  local parts = {}
  if note_buf and vim.api.nvim_buf_is_valid(note_buf) then
    local note = vim.trim(table.concat(vim.api.nvim_buf_get_lines(note_buf, 0, -1, false), "\n"))
    if note ~= "" then
      parts[#parts + 1] = note
    end
  end
  local items = A.list()
  if #items > 0 then
    local out = { "# Annotations on the conversation above" }
    for i, item in ipairs(items) do
      local quoted = table.concat(A.text(item), "\n")
      local body = vim.trim(item.body)
      out[#out + 1] = ""
      out[#out + 1] = "## Annotation " .. i
      if item.kind == "delete" then
        out[#out + 1] = "Remove this:"
        out[#out + 1] = fenced(quoted)
        out[#out + 1] = quote_lines(body ~= "" and body or "I don't want this.")
      elseif item.kind == "good" then
        out[#out + 1] = 'Looks good: "' .. single_line(quoted) .. '"'
        if body ~= "" then
          out[#out + 1] = quote_lines(body)
        end
      else
        out[#out + 1] = 'Comment on: "' .. single_line(quoted) .. '"'
        out[#out + 1] = quote_lines(body)
      end
    end
    parts[#parts + 1] = table.concat(out, "\n")
  end
  return table.concat(parts, "\n\n")
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
    return
  end
  local out = assert(io.open(reply_path, "wb"))
  out:write(text, "\n")
  out:close()
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
vim.keymap.set("n", "+", operator("good"), ebo)
vim.keymap.set("n", "a", operator("comment", "_"), ebo)
vim.keymap.set("x", "c", operator("comment"), ebo)
vim.keymap.set("x", "d", operator("delete"), ebo)
vim.keymap.set("x", "+", operator("good"), ebo)
vim.keymap.set("x", "a", operator("comment"), ebo)
vim.keymap.set("x", "<CR>", operator("comment"), ebo)
vim.keymap.set("o", "c", line_motion("comment", "c"), ebo)
vim.keymap.set("o", "d", line_motion("delete", "d"), ebo)
vim.keymap.set("o", "+", line_motion("good", "+"), ebo)
vim.keymap.set("n", "]a", function()
  M.jump(1, vim.v.count1)
end, bo)
vim.keymap.set("n", "[a", function()
  M.jump(-1, vim.v.count1)
end, bo)
vim.keymap.set("n", "K", M.hover, bo)
vim.keymap.set("n", "e", M.edit, bo)
vim.keymap.set("n", "x", M.remove_at_cursor, bo)
vim.keymap.set("n", "q", "<Cmd>qa<CR>", bo)
vim.keymap.set("n", "<Tab>", function()
  vim.api.nvim_set_current_win(ensure_note())
end, bo)
unshadow_triggers()

vim.wo.winbar = thread_winbar()
hide_chrome()

local function find_in_thread(text)
  local needle = text:gsub("%s+", "")
  if needle == "" then
    return nil
  end
  local hay, rows, cols = {}, {}, {}
  for r, l in ipairs(vim.api.nvim_buf_get_lines(thread, 0, -1, false)) do
    for pos, ch in l:gmatch("()(%S)") do
      hay[#hay + 1] = ch
      rows[#rows + 1] = r - 1
      cols[#cols + 1] = pos - 1
    end
  end
  hay = table.concat(hay)
  local last
  local init = 1
  while true do
    local s = hay:find(needle, init, true)
    if not s then
      break
    end
    last = s
    init = s + 1
  end
  if not last then
    return nil
  end
  local e = last + #needle - 1
  return { srow = rows[last], scol = cols[last], erow = rows[e], ecol = cols[e] + 1, linewise = false }
end
M.find_in_thread = find_in_thread

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
end, 1500)
