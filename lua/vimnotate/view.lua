local M = require("vimnotate")
local core = require("vimnotate.core")
local store = require("vimnotate.store")
local boxes = require("vimnotate.boxes")
local rail = require("vimnotate.rail")
local chrome = require("vimnotate.chrome")
local A = store.A
local thread = core.thread
local thread_win = core.thread_win
local line_len = core.line_len
local before = core.before
local view = core.view
local back_to_thread = core.back_to_thread
local accent_of = boxes.accent_of
local bubble = boxes.bubble
local frame = boxes.frame
local KINDS = core.KINDS
local rail_valid = rail.valid
local rail_render = rail.render
local rail_width = rail.width
local total_width = rail.total_width
local rail_open = rail.open
local rail_close = rail.close
local scroll_thread = rail.scroll_thread
local refresh_winbar = chrome.refresh_winbar

local RAIL_MIN_THREAD = 80
local RAIL_FORCE_MIN_THREAD = 40
local INLINE_INDENT = 2
local FLASH_MS = 2500
local Q_GUARD_MS = 400
local inline_ns = vim.api.nvim_create_namespace("vimnotate.inline")
local inline_boxes = {}

local Vw = {}

local function box_width(info)
  return math.max(info.width - info.textoff - INLINE_INDENT, 12)
end

local function inline_render()
  vim.api.nvim_buf_clear_namespace(thread, inline_ns, 0, -1)
  inline_boxes = {}
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
      local b = bubble(e.item, width, edge, true)
      inline_boxes[e.item.id] = { erow = erow, offset = #groups[erow], rows = #b }
      for _, row in ipairs(b) do
        table.insert(row, 1, { string.rep(" ", INLINE_INDENT) })
        table.insert(groups[erow], row)
      end
    else
      c.offset = #groups[erow]
      if c.inline then
        local blank = {}
        for _ = 1, c.rows - 2 do
          blank[#blank + 1] = ""
        end
        for _, row in ipairs(frame(c.title or "", "VimnotateTitle", blank, nil, width, KINDS[c.kind].hl .. "Border", false)) do
          table.insert(row, 1, { string.rep(" ", INLINE_INDENT) })
          table.insert(groups[erow], row)
        end
      else
        for _ = 1, c.rows do
          table.insert(groups[erow], { { " " } })
        end
      end
    end
  end
  for erow, vl in pairs(groups) do
    vim.api.nvim_buf_set_extmark(thread, inline_ns, erow, 0, { virt_lines = vl })
  end
  view.last_sel = sel
end
M.inline_render = inline_render

function M.item_shown(item)
  local tw = thread_win()
  if tw == -1 then
    return false
  end
  if view.mode == "rail" then
    for _, b in ipairs(view.bubbles or {}) do
      if b.item == item then
        return b.whole
      end
    end
    return false
  end
  local box = view.mode == "inline" and inline_boxes[item.id]
  if not box then
    return false
  end
  local sv = vim.api.nvim_win_call(tw, vim.fn.winsaveview)
  if box.erow < sv.topline - 1 then
    return false
  end
  local above = vim.api.nvim_win_text_height(tw, { start_row = sv.topline - 1, start_vcol = sv.skipcol, end_row = box.erow }).all
  return (sv.topfill or 0) + above + box.offset + box.rows <= vim.fn.getwininfo(tw)[1].height
end

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
    x = info.textoff + INLINE_INDENT + 2
  else
    local sp = vim.fn.screenpos(tw, r.srow + 1, (r.linewise and 0 or r.scol) + 1)
    x = sp.col > 0 and (sp.col - info.wincol) or 0
  end
  x = math.max(0, math.min(x, info.width - c.width - (c.inline and 0 or 2)))
  return {
    relative = "win",
    win = tw,
    width = c.width,
    height = c.height,
    bufpos = { r.erow, ecol },
    anchor = "NW",
    row = (c.inline and 2 or 1) + (c.offset or 0),
    col = ep.col > 0 and (x - (ep.col - info.wincol)) or x,
  }
end

local function view_setting()
  local v = view.setting
  if v == "rail" or v == "auto" or v == "off" then
    return v
  end
  return "inline"
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
  M.bars_refresh()
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

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

local function q_guarded()
  return view.returned_at ~= nil and now_ms() - view.returned_at < Q_GUARD_MS
end
M.q_guarded = q_guarded

function M.send_key()
  if q_guarded() then
    flash("q sends")
    return
  end
  vim.cmd("qa")
end

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
  view.setting = nxt
  back_to_thread()
  apply_view()
  local note = nxt == "rail" and " (S-Tab focus)" or ""
  if nxt ~= "off" and next(A.items) == nil then
    note = " (shown with the first annotation)"
  end
  flash("view: " .. nxt .. note)
end

local resize_pending = false

function Vw.setup()
  local view_group = vim.api.nvim_create_augroup("vimnotate.view", { clear = true })
  local left_win
  vim.api.nvim_create_autocmd("WinLeave", {
    group = view_group,
    callback = function()
      left_win = vim.api.nvim_get_current_win()
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = view_group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) == thread and left_win and left_win ~= win then
        view.returned_at = now_ms()
      end
    end,
  })
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
          view.setting = "off"
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
end

return Vw
