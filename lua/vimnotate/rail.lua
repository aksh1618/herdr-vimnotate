local M = require("vimnotate")
local core = require("vimnotate.core")
local store = require("vimnotate.store")
local boxes = require("vimnotate.boxes")
local B = require("vimnotate.bars")
local A = store.A
local thread = core.thread
local thread_win = core.thread_win
local warn = core.warn
local view = core.view
local note_text = core.note_text
local back_to_thread = core.back_to_thread
local range_ns = A.range_ns
local dw = boxes.dw
local wrap_text = boxes.wrap_text
local accent_of = boxes.accent_of
local frame = boxes.frame
local bubble = boxes.bubble
local cut_rows = boxes.cut_rows
local bars_hide = B.hide

local RAIL_WIDTH = 36
local RAIL_MIN_WIDTH = 28
local rail_ns = vim.api.nvim_create_namespace("vimnotate.rail")

local R = {}

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

local RAIL_HINTS = "j/k ⏎ jump · e edit · x remove · esc"

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
  core.tint_winbar(win)
  vim.wo[win].winbar = rail_winbar()
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
    B.pending_click = function()
      M.rail_click(m.line)
    end
    B.swallow = true
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

M.wheel = wheel
M.rail_scrub = function()
  if rail_valid() then
    rail_scrub(view.rail_win)
  end
end

R.valid = rail_valid
R.render = rail_render
R.width = rail_width
R.total_width = total_width
R.open = rail_open
R.close = rail_close
R.scroll_thread = scroll_thread

return R
