local M = require("vimnotate")
local core = require("vimnotate.core")
local store = require("vimnotate.store")
local A = store.A
local thread = core.thread
local thread_win = core.thread_win
local KINDS = core.KINDS
local view = core.view
local line_len = core.line_len

local B = { swallow = false, pending_click = nil }

local BAR_ACTIONS = {
  { kind = "good", label = "looks good" },
  { kind = "comment", label = "comment" },
  { kind = "delete", label = "delete" },
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

local function bar_setting()
  local v = vim.env.VIMNOTATE_ACTION_BAR
  if v == "mouse" or v == "never" then
    return v
  end
  return "always"
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

function bars.pieces(entries, hl)
  local pieces = {}
  for _, e in ipairs(entries) do
    local key = e.key and (" (" .. e.key .. ")") or ""
    pieces[#pieces + 1] = { text = " " .. e.glyph .. " " .. e.label .. key .. " ", hl = hl or e.hl, run = e.run }
  end
  return pieces
end

local function action_pieces()
  return bars.pieces(vim.tbl_map(function(a)
    local kind = KINDS[a.kind]
    return {
      glyph = kind.glyph,
      label = a.label,
      key = not core.textobj_prefix(core.keys[a.kind]) and core.keys[a.kind] or nil,
      hl = "VimnotateBar" .. kind.hl:sub(10),
      run = function()
        vim.api.nvim_feedkeys(vim.keycode("<Plug>(vimnotate-" .. a.kind .. ")"), "m", false)
      end,
    }
  end, BAR_ACTIONS))
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
  local entries = {
    { glyph = "📝", label = "edit", key = "e", run = M.edit },
    { glyph = "🧹", label = "remove", key = "x", run = M.remove_at_cursor },
  }
  local shown = M.item_shown(item)
  if not shown then
    entries[#entries + 1] = { glyph = "🔍", label = "show", key = "K", run = M.hover }
  end
  bar_render(bars.hint, bars.pieces(entries, "VimnotateBar" .. KINDS[item.kind].hl:sub(10)))
  bar_show(bars.hint, A.range(item))
  hint_item = item
  bars.hint.shown = shown
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
    if not A.items[hint_item.id] then
      hint_hide()
    elseif M.item_shown(hint_item) ~= bars.hint.shown then
      hint_render(hint_item)
    else
      bar_show(bars.hint, A.range(hint_item))
    end
  end
end
M.bars_refresh = bars_refresh

function M.bar_click()
  local run = B.pending_click
  B.pending_click = nil
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
      B.pending_click = function()
        M.rail_click(m.line)
      end
      B.swallow = true
      return "<Cmd>lua require('vimnotate').bar_click()<CR>"
    end
    local run = bar_hit(bar)
    if not run then
      return "<LeftMouse>"
    end
    B.pending_click = run
    B.swallow = true
    return "<Cmd>lua require('vimnotate').bar_click()<CR>"
  end
end

function B.setup()
  vim.on_key(function(_, typed)
    if not typed or typed == "" then
      return
    end
    local base = typed:sub(-3)
    local left = base == LEFT_PRESS or base == LEFT_DRAG or base == LEFT_RELEASE
    local tw = thread_win()
    if tw ~= -1 and left and bars.scrolloff == nil then
      bars.scrolloff = vim.api.nvim_get_option_value("scrolloff", { scope = "local", win = tw })
      vim.api.nvim_set_option_value("scrolloff", 0, { scope = "local", win = tw })
    elseif tw ~= -1 and not left and bars.scrolloff ~= nil then
      vim.api.nvim_set_option_value("scrolloff", bars.scrolloff, { scope = "local", win = tw })
      bars.scrolloff = nil
    end
    if B.swallow then
      if base == LEFT_DRAG then
        return ""
      end
      B.swallow = false
      if base == LEFT_RELEASE then
        return ""
      end
    end
    by_mouse = left
  end, vim.api.nvim_create_namespace("vimnotate.mouse"))

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
end

B.bars = bars
B.hide = bars_hide
B.hint_hide = hint_hide

return B
