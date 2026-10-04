local M = require("vimnotate")
local core = require("vimnotate.core")
local thread = core.thread
local thread_win = core.thread_win
local KINDS = core.KINDS
local warn = core.warn
local line_len = core.line_len
local before = core.before
local single_line = core.single_line

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

local S = { A = A, H = H }

function S.setup()
  vim.on_key(function()
    H.step = nil
  end, vim.api.nvim_create_namespace("vimnotate.history"))
end

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

return S
